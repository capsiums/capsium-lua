# frozen_string_literal: true

# Conformance-kit adapter for the capsium-lua (OpenResty/nginx) reactor.
#
# The Capsium conformance kit loads this file
# (CONFORMANCE_ADAPTER=<path>/conformance_reactor_adapter.rb) and calls
# ReactorAdapterUnderTest#start(package_path, **options) once per fixture.
#
# Every start:
#   1. ensures the reactor image (capsium-nginx:test) is built from the
#      repository Dockerfile (set CONFORMANCE_REBUILD=1 to force a rebuild
#      after reactor code changes),
#   2. generates a scratch configuration: a config.json mounting the
#      fixture .cap at "/" — plus the decryption key, deploy
#      authentication block or package store when the fixture's serve
#      options call for them — and an nginx conf.d derived from the
#      repository's, minus the welcome-page `location = /` (the fixture
#      package owns "/"),
#   3. runs a detached container publishing port 80 on an ephemeral
#      loopback port (`docker run -d --rm -p 127.0.0.1:0:80`, discovered
#      via `docker port`),
#   4. waits until nginx answers, then probes the mounted package: a 5xx
#      means the reactor rejected it (tampered, bad signature, encrypted
#      without key) and start raises StartError, as the kit contract
#      requires for the negative fixtures.
#
# stop removes the container and the scratch directory; it is idempotent.
#
# Only Docker and Ruby stdlib are used: the reactor never runs on the
# host.

require "fileutils"
require "json"
require "net/http"
require "open3"
require "tmpdir"
require "timeout"

class ReactorAdapterUnderTest < CapsiumConformance::ReactorAdapter
  REPO_ROOT = File.expand_path("..", __dir__)
  IMAGE = "capsium-nginx:test"
  DEFAULT_TIMEOUT = 20

  # Container-side paths (the image layout, see Dockerfile)
  CONTAINER_PACKAGES = "/var/lib/capsium/packages"
  CONTAINER_STORE = "/var/lib/capsium/store"
  CONTAINER_KEY = "/etc/capsium/keys/private.pem"
  CONTAINER_CONFIG = "/etc/capsium/config.json"

  @image_checked = false

  class << self
    # Build the reactor image once per process (docker layer caching makes
    # repeat runs cheap); CONFORMANCE_REBUILD=1 forces a rebuild.
    def ensure_image
      return if @image_checked && !ENV["CONFORMANCE_REBUILD"]

      unless system("docker", "image", "inspect", IMAGE,
                    out: File::NULL, err: File::NULL) &&
             !ENV["CONFORMANCE_REBUILD"]
        build_image
      end
      @image_checked = true
    end

    def build_image
      _out, err, status = Open3.capture3(
        "docker", "build", "-t", IMAGE, ".", chdir: REPO_ROOT
      )
      return if status.success?

      raise CapsiumConformance::ReactorAdapter::StartError,
            "failed to build the reactor image #{IMAGE}:\n#{err.lines.last(30).join}"
    end
  end

  def start(package_path, port: nil, store: nil, deploy: nil,
            decryption_key: nil, timeout: DEFAULT_TIMEOUT, env: {}, **)
    stop # defensive: a reused instance never leaks its previous container
    self.class.ensure_image

    @package_name = File.basename(package_path)
    @workdir = Dir.mktmpdir("capsium-conformance")
    write_configuration(package_path, store, deploy, decryption_key)

    @container_id = run_container(package_path, port, store, env)
    @port = port || discover_port

    response = wait_until_ready(timeout)
    if response.code.to_i >= 500
      raise StartError, "reactor rejected #{@package_name}: " \
                        "HTTP #{response.code} " \
                        "#{response.body.to_s[0, 300]}\nlog:\n#{log_tail}"
    end
    "http://127.0.0.1:#{@port}"
  rescue StartError
    stop
    raise
  end

  def stop
    if @container_id
      system("docker", "rm", "-f", @container_id,
             out: File::NULL, err: File::NULL)
      @container_id = nil
    end
    return unless @workdir

    FileUtils.remove_entry(@workdir)
    @workdir = nil
  end

  private

  # ------------------------------------------------------------------
  # Configuration generation
  # ------------------------------------------------------------------

  def write_configuration(package_path, store, deploy, decryption_key)
    config_dir = File.join(@workdir, "config")
    FileUtils.mkdir_p(File.join(config_dir, "keys"))
    FileUtils.mkdir_p(File.join(@workdir, "conf.d"))

    config = {
      "package_dir" => CONTAINER_PACKAGES,
      "extract_dir" => "/var/lib/capsium/extracted",
      "store_dir" => CONTAINER_STORE,
      "cache_enabled" => false, # deterministic reports for the kit
      "log_level" => "info",
      "mounts" => [{ "package" => File.basename(package_path),
                     "path" => "/" }]
    }

    if decryption_key
      FileUtils.cp(decryption_key, File.join(config_dir, "keys",
                                             "private.pem"))
      config["encryption"] = { "privateKeyPath" => CONTAINER_KEY }
    end

    # Reactor-side deploy config (e.g. the auth fixture's role
    # assignments): merge its authentication block into the generated
    # config.json
    if deploy
      deploy_config = JSON.parse(File.read(deploy))
      if deploy_config["authentication"].is_a?(Hash)
        config["authentication"] = deploy_config["authentication"]
      end
    end

    File.write(File.join(config_dir, "config.json"),
               JSON.pretty_generate(config))

    # The repository nginx conf serves a welcome page at exactly "/"; the
    # fixture package must own "/" instead, so strip that location block.
    File.write(File.join(@workdir, "conf.d", "capsium.conf"),
               strip_welcome_location(
                 File.read(File.join(REPO_ROOT, "nginx", "conf.d",
                                     "capsium.conf"))))
  end

  # Remove the `location = / { ... }` block (and its leading comment) from
  # the repository's capsium.conf.
  def strip_welcome_location(conf)
    lines = conf.lines
    start = lines.index { |line| line =~ /^\s*location = \/ \{/ }
    return conf unless start

    depth = 0
    finish = nil
    (start...lines.length).each do |i|
      depth += lines[i].count("{")
      depth -= lines[i].count("}")
      if depth.zero?
        finish = i
        break
      end
    end
    raise StartError, "could not parse the welcome location block" unless finish

    first = start
    first -= 1 while first.positive? && lines[first - 1].strip.start_with?("#")

    stripped = (lines[0...first] + lines[(finish + 1)..]).join
    if stripped =~ /location = \//
      raise StartError, "failed to strip the welcome location block"
    end

    stripped
  end

  # ------------------------------------------------------------------
  # Container lifecycle
  # ------------------------------------------------------------------

  def run_container(package_path, port, store, env)
    publish = port ? "127.0.0.1:#{port}:80" : "127.0.0.1:0:80"
    cmd = [
      "docker", "run", "-d", "--rm",
      "-p", publish,
      "-v", "#{File.expand_path(package_path)}:" \
            "#{CONTAINER_PACKAGES}/#{@package_name}:ro",
      "-v", "#{@workdir}/config:/etc/capsium:ro",
      "-v", "#{@workdir}/conf.d:/etc/nginx/conf.d:ro",
      "-e", "CAPSIUM_CONFIG_PATH=#{CONTAINER_CONFIG}"
    ]
    cmd += ["-v", "#{File.expand_path(store)}:#{CONTAINER_STORE}:ro"] if store
    env.each { |key, value| cmd += ["-e", "#{key}=#{value}"] }
    cmd << IMAGE

    out, err, status = Open3.capture3(*cmd)
    unless status.success?
      raise StartError, "docker run failed for #{@package_name}:\n#{err}"
    end

    out.strip
  end

  # The host port docker bound for the container's port 80.
  def discover_port
    out, err, status = Open3.capture3("docker", "port", @container_id, "80")
    unless status.success?
      raise StartError, "docker port failed:\n#{err}"
    end

    match = out.match(/127\.0\.0\.1:(\d+)/)
    raise StartError, "no loopback port mapping found: #{out}" unless match

    match[1].to_i
  end

  def container_running?
    out, _err, status = Open3.capture3("docker", "inspect", "-f",
                                       "{{.State.Running}}", @container_id)
    status.success? && out.strip == "true"
  end

  # Poll the mount until nginx answers; a container that exits first means
  # the reactor never came up. Returns the first HTTP response (any
  # status — the caller decides what it means).
  def wait_until_ready(timeout)
    Timeout.timeout(timeout) do
      loop do
        response = probe
        return response if response
        unless container_running?
          raise StartError, "reactor container exited before serving " \
                            "(#{@package_name}); log:\n#{log_tail}"
        end

        sleep(0.1)
      end
    end
  rescue Timeout::Error
    raise StartError, "reactor did not become ready within #{timeout}s " \
                      "(#{@package_name}); log:\n#{log_tail}"
  end

  # One GET against the mounted package root; nil while nginx is not yet
  # answering. The first request triggers extraction and integrity
  # verification, so the response status is the reactor's verdict.
  def probe
    Net::HTTP.start("127.0.0.1", @port, open_timeout: 1,
                                        read_timeout: 10) do |http|
      http.request(Net::HTTP::Get.new("/"))
    end
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError, SocketError,
         Net::OpenTimeout, Net::ReadTimeout
    nil
  end

  def log_tail
    out, err, = Open3.capture3("docker", "logs", "--tail", "15",
                               @container_id)
    text = (out + err).strip
    text.empty? ? "(no log)" : text
  rescue StandardError
    "(no log)"
  end
end
