# frozen_string_literal: true

# Builds the generated .cap test fixtures:
#
#   canonical-sample-1.0.0.cap    canonical schemas + security.json (SHA-256)
#   canonical-tampered-1.0.0.cap  same, but content/about.html is modified
#                                 after checksums are computed (integrity
#                                 rejection test vector)
#   multi-test-1.0.0.cap          legacy-schemas multi-package fixture
#   dormant-package-0.1.0.cap     minimal package (cold-start tests)
#   signed-sample-1.0.0.cap       + digitalSignatures + valid signature.sig
#                                 (ARCHITECTURE.md section 6a)
#   signed-tampered-1.0.0.cap     valid checksums but a signature that does
#                                 NOT match (signature rejection vector)
#
# Uses Ruby's Digest::SHA256 and the system `zip` binary — no gem
# dependencies. Run via `rake fixtures` or directly:
#
#   ruby spec/fixtures/build_fixtures.rb

require 'digest'
require 'fileutils'
require 'json'
require 'openssl'

FIXTURES_DIR = __dir__
SRC_DIR = File.join(FIXTURES_DIR, 'src')

# Recursively collect files under dir as relative POSIX paths, skipping
# dotfiles (.DS_Store and friends).
def collect_files(dir, prefix = '')
  files = []
  Dir.entries(dir).sort.each do |entry|
    next if entry.start_with?('.')

    path = File.join(dir, entry)
    rel = prefix.empty? ? entry : "#{prefix}/#{entry}"

    if File.directory?(path)
      files.concat(collect_files(path, rel))
    else
      files << rel
    end
  end
  files
end

# Copy a source tree into a staging directory.
def stage(src, staging)
  collect_files(src).each do |rel|
    dest = File.join(staging, rel)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(File.join(src, rel), dest)
  end
end

# Write security.json covering every staged file (SHA-256 hex).
def write_security_json(staging)
  checksums = {}
  collect_files(staging).each do |rel|
    next if rel == 'security.json'

    hex = Digest::SHA256.file(File.join(staging, rel)).hexdigest
    checksums[rel] = hex
  end

  security = {
    security: {
      integrityChecks: {
        checksumAlgorithm: 'SHA-256',
        checksums: checksums
      }
    }
  }
  File.write(File.join(staging, 'security.json'), JSON.pretty_generate(security))
end

# Sign a staged package in place, mirroring the Ruby gem's Signer
# (ARCHITECTURE.md section 6a):
#   1. embed the public key PEM (covered by the checksums),
#   2. write security.json: checksums over every file except security.json
#      and signature.sig, plus the digitalSignatures block,
#   3. write signature.sig: raw RSA-SHA256 over the concatenation, in
#      sorted path order, of the bytes of the checksum-covered files.
#
# bad_signature: sign a different payload so the checksums stay valid but
# the signature must be rejected.
def sign_staging(staging, key, bad_signature: false)
  File.write(File.join(staging, 'signature.pub.pem'), key.public_key.to_pem)

  checksums = {}
  collect_files(staging).each do |rel|
    next if %w[security.json signature.sig].include?(rel)

    checksums[rel] = Digest::SHA256.file(File.join(staging, rel)).hexdigest
  end

  security = {
    security: {
      integrityChecks: {
        checksumAlgorithm: 'SHA-256',
        checksums: checksums
      },
      digitalSignatures: {
        publicKey: 'signature.pub.pem',
        signatureFile: 'signature.sig'
      }
    }
  }
  File.write(File.join(staging, 'security.json'), JSON.pretty_generate(security))

  payload = checksums.keys.sort.map do |rel|
    File.binread(File.join(staging, rel))
  end.join
  payload = 'a payload that was never in the package' if bad_signature
  File.binwrite(File.join(staging, 'signature.sig'), key.sign('SHA256', payload))
end

# Zip the staging directory contents into out_path (paths relative to root).
def zip_dir(staging, out_path)
  FileUtils.rm_f(out_path)
  Dir.chdir(staging) do
    files = collect_files('.').map { |f| f.sub(%r{^\./}, '') }
    system('zip', '-q', '-X', out_path, *files) or
      abort "zip failed for #{out_path}"
  end
end

def build(name, src_name: nil, with_security: false, tamper: nil,
          sign_with: nil, bad_signature: false)
  src = File.join(SRC_DIR, src_name || name)
  staging = File.join(FIXTURES_DIR, 'tmp-build', name)
  out = File.join(FIXTURES_DIR, "#{name}.cap")

  FileUtils.rm_rf(staging)
  FileUtils.mkdir_p(staging)
  stage(src, staging)

  if sign_with
    sign_staging(staging, sign_with, bad_signature: bad_signature)
  elsif with_security
    write_security_json(staging)
  end

  # Tamper AFTER checksums are computed so the package fails verification
  if tamper
    File.write(File.join(staging, tamper),
               File.read(File.join(staging, tamper)) + "\n<!-- tampered -->\n")
  end

  zip_dir(staging, out)
  FileUtils.rm_rf(staging)
  puts "built #{out}"
end

# multi-package-test lives directly under fixtures/ (legacy fixture dir)
def build_legacy(name, src_dir)
  staging = File.join(FIXTURES_DIR, 'tmp-build', name)
  out = File.join(FIXTURES_DIR, "#{name}.cap")

  FileUtils.rm_rf(staging)
  FileUtils.mkdir_p(staging)
  stage(src_dir, staging)
  zip_dir(staging, out)
  FileUtils.rm_rf(staging)
  puts "built #{out}"
end

build('canonical-sample-1.0.0', with_security: true)
# The tampered fixture shares the canonical source tree; about.html is
# modified after checksums are computed so verification must reject it.
build('canonical-tampered-1.0.0', src_name: 'canonical-sample-1.0.0',
                                  with_security: true,
                                  tamper: 'content/about.html')
build_legacy('multi-test-1.0.0', File.join(FIXTURES_DIR, 'multi-package-test'))
build('dormant-package-0.1.0')

# Test RSA key pair (test-only): the private key is also used by the
# encrypted-package fixtures and the reactor's decryption config.
KEYS_DIR = File.join(FIXTURES_DIR, 'keys')
FileUtils.mkdir_p(KEYS_DIR)
signing_key = OpenSSL::PKey::RSA.generate(2048)
File.write(File.join(KEYS_DIR, 'private.pem'), signing_key.to_pem)
File.write(File.join(KEYS_DIR, 'public.pem'), signing_key.public_key.to_pem)

build('signed-sample-1.0.0', sign_with: signing_key)
# Checksums are valid; the signature is over a foreign payload and must be
# rejected by the signature gate.
build('signed-tampered-1.0.0', src_name: 'signed-sample-1.0.0',
                               sign_with: signing_key, bad_signature: true)
