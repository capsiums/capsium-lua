require 'rspec/core/rake_task'

# Configuration
CONTAINER_NAME = 'capsium-nginx-test'
IMAGE_NAME = 'capsium-nginx:test'
BASE_IMAGE = 'openresty/openresty:alpine-fat'
DOCKER_PORT = '8080:80'

# Helper methods
def container_running?
  system("docker ps --filter name=#{CONTAINER_NAME} --filter status=running -q | grep -q .",
         out: File::NULL, err: File::NULL)
end

def container_exists?
  system("docker ps -a --filter name=#{CONTAINER_NAME} -q | grep -q .",
         out: File::NULL, err: File::NULL)
end

def wait_for_server(max_attempts: 30)
  puts "Waiting for server to be ready..."
  max_attempts.times do |i|
    if system("curl -s http://localhost:8080/ > /dev/null 2>&1")
      puts "Server is ready!"
      return true
    end
    print "Waiting... (#{i + 1}/#{max_attempts})\n"
    sleep 1
  end
  puts "Server failed to start in time"
  false
end

# Default task
task default: :test

# Installation
desc "Install Ruby dependencies"
task :install do
  sh "bundle install"
end

# Docker tasks
namespace :docker do
  desc "Build Docker image"
  task :build do
    puts "Building Docker image..."
    sh "docker build -t #{IMAGE_NAME} --build-arg BASE_IMAGE=#{BASE_IMAGE} ."
  end

  desc "Start Docker container (or reuse if already running)"
  task :start do
    if container_running?
      puts "Container '#{CONTAINER_NAME}' is already running, reusing it..."
    else
      if container_exists?
        puts "Removing stopped container '#{CONTAINER_NAME}'..."
        sh "docker rm #{CONTAINER_NAME}", verbose: false
      end

      puts "Starting Docker container..."
      sh <<~SH
        docker run -d --name #{CONTAINER_NAME} \
          -p #{DOCKER_PORT} \
          -v #{Dir.pwd}/config:/etc/capsium \
          -v #{Dir.pwd}/lua/capsium:/etc/nginx/lua/capsium \
          -v #{Dir.pwd}/lib/capsium:/usr/local/openresty/luajit/share/lua/5.1/capsium \
          -v #{Dir.pwd}/nginx/conf.d:/etc/nginx/conf.d \
          -v #{Dir.pwd}/nginx/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf \
          -v #{Dir.pwd}/spec/fixtures:/var/lib/capsium/packages \
          -v #{Dir.pwd}/spec/static:/var/lib/capsium/static \
          -e CAPSIUM_CONFIG_PATH=/etc/capsium/config.json \
          #{IMAGE_NAME}
      SH

      unless wait_for_server
        sh "docker logs #{CONTAINER_NAME}"
        abort "Failed to start server"
      end
    end
  end

  desc "Stop Docker container"
  task :stop do
    if container_exists?
      puts "Stopping Docker container..."
      sh "docker stop #{CONTAINER_NAME}", verbose: false
      sh "docker rm #{CONTAINER_NAME}", verbose: false
      puts "Container stopped and removed"
    else
      puts "Container '#{CONTAINER_NAME}' does not exist"
    end
  end

  desc "Restart Docker container"
  task restart: [:stop, :start]

  desc "View container logs"
  task :logs do
    if container_exists?
      sh "docker logs --tail 100 -f #{CONTAINER_NAME}"
    else
      puts "Container '#{CONTAINER_NAME}' does not exist"
    end
  end

  desc "Open a shell in the container"
  task :shell do
    if container_running?
      sh "docker exec -it #{CONTAINER_NAME} /bin/sh"
    else
      puts "Container '#{CONTAINER_NAME}' is not running"
    end
  end

  desc "Clean up containers and images"
  task :clean do
    Rake::Task['docker:stop'].invoke
    puts "Removing Docker image..."
    sh "docker rmi #{IMAGE_NAME}", verbose: false rescue nil
  end
end

# RSpec tasks
desc "Run all specs with documentation format"
RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = 'spec/**/*_spec.rb'
  t.rspec_opts = '--format documentation'
end

namespace :spec do
  desc "Run all specs"
  task all: :spec

  desc "Run specs and generate reports for CI"
  RSpec::Core::RakeTask.new(:ci_report) do |t|
    t.pattern = 'spec/**/*_spec.rb'
    t.rspec_opts = '--format documentation --format json --out tmp/rspec_results.json'
  end

  desc "Run API specs only"
  RSpec::Core::RakeTask.new(:api) do |t|
    t.pattern = 'spec/api_spec.rb'
    t.rspec_opts = '--format documentation'
  end

  desc "Run package specs only"
  RSpec::Core::RakeTask.new(:packages) do |t|
    t.pattern = 'spec/packages_spec.rb'
    t.rspec_opts = '--format documentation'
  end

  desc "Run configuration specs only"
  RSpec::Core::RakeTask.new(:config) do |t|
    t.pattern = 'spec/config_spec.rb'
    t.rspec_opts = '--format documentation'
  end

  desc "Run basic specs only"
  RSpec::Core::RakeTask.new(:basic) do |t|
    t.pattern = 'spec/basic_spec.rb'
    t.rspec_opts = '--format documentation'
  end
end

# Combined workflow tasks
desc "Run tests (ensures container is running)"
task test: ['docker:start', :spec]

desc "CI workflow: build, start, test, cleanup"
task :ci do
  begin
    # Ensure tmp directory exists for JSON report
    FileUtils.mkdir_p('tmp')
    Rake::Task['docker:build'].invoke
    Rake::Task['docker:start'].invoke
    Rake::Task['spec:ci_report'].invoke
  ensure
    Rake::Task['docker:stop'].invoke
  end
end

# Cleanup task
desc "Clean all artifacts and containers"
task clean: ['docker:clean'] do
  puts "Removing test artifacts..."
  FileUtils.rm_rf('tmp')
  FileUtils.rm_rf('.rspec_status')
end

# Help task
desc "List all available tasks"
task :help do
  puts "\nAvailable Rake tasks:\n\n"
  system("rake -T")
end
