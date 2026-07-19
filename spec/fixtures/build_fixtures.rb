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
#   encrypted-sample-1.0.0.cap    encrypted layout (section 6b): metadata.json
#                                 + signature.json envelope + package.enc
#                                 (AES-256-GCM inner zip, RSA-OAEP-SHA256 DEK)
#   layered-sample-1.0.0.cap      storage.layers base+updates (section 5a):
#                                 top-wins override + .capsium-tombstones 404
#   composite-sample-1.0.0.cap    depends on capsium://fixtures/vendor-core
#                                 (section 4a); the store (fixtures/store/)
#                                 offers vendor-core 1.0.0 + 1.1.0
#   registry/                     static registry fixture: index.json + .cap
#                                 files for registry-app 1.0.0/1.1.0 (mount
#                                 sources capsium://fixtures/registry-app)
#                                 and registry-tampered 1.0.0 (index sha256
#                                 deliberately wrong: install must be
#                                 rejected with a checksum mismatch)
#
# Keys (test-only, regenerated each run) land in spec/fixtures/keys/:
#   private.pem/public.pem              signing + encryption recipient
#   other-private.pem/other-public.pem  unrelated pair (wrong-key tests)
#
# Uses Ruby's Digest::SHA256 and the system `zip` binary — no gem
# dependencies. Run via `rake fixtures` or directly:
#
#   ruby spec/fixtures/build_fixtures.rb

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'openssl'

FIXTURES_DIR = __dir__
SRC_DIR = File.join(FIXTURES_DIR, 'src')

# Recursively collect files under dir as relative POSIX paths, skipping
# dotfiles (.DS_Store and friends). Package-artifact dotfiles (section 5a's
# .capsium-tombstones, section 4b's .htpasswd) are kept.
DOTFILE_ALLOWLIST = %w[.capsium-tombstones .htpasswd].freeze

def collect_files(dir, prefix = '')
  files = []
  Dir.entries(dir).sort.each do |entry|
    next if entry.start_with?('.') && !DOTFILE_ALLOWLIST.include?(entry)

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
          sign_with: nil, bad_signature: false, out_dir: FIXTURES_DIR)
  src = File.join(SRC_DIR, src_name || name)
  staging = File.join(FIXTURES_DIR, 'tmp-build', name)
  out = File.join(out_dir, "#{name}.cap")

  FileUtils.rm_rf(staging)
  FileUtils.mkdir_p(staging)
  FileUtils.mkdir_p(out_dir)
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

# Build an encrypted package (ARCHITECTURE.md section 6b) for the
# recipient's RSA public key, mirroring the Ruby gem's Cipher:
# the inner zip is the normal (checksummed) package; the outer zip holds
# metadata.json (cleartext), signature.json (the envelope) and
# package.enc (AES-256-GCM ciphertext of the inner zip). The DEK is
# wrapped with RSA-OAEP-SHA256 (MGF1-SHA256).
RSA_OPTIONS = {
  'rsa_padding_mode' => 'oaep',
  'rsa_oaep_md' => 'SHA256',
  'rsa_mgf1_md' => 'SHA256'
}.freeze

def build_encrypted(name, public_key)
  inner_staging = File.join(FIXTURES_DIR, 'tmp-build', "#{name}-inner")
  outer_staging = File.join(FIXTURES_DIR, 'tmp-build', "#{name}-outer")
  inner_cap = File.join(FIXTURES_DIR, 'tmp-build', "#{name}-inner.cap")
  out = File.join(FIXTURES_DIR, "#{name}.cap")

  # Inner package (with integrity checksums)
  FileUtils.rm_rf(inner_staging)
  FileUtils.mkdir_p(inner_staging)
  stage(File.join(SRC_DIR, name), inner_staging)
  write_security_json(inner_staging)
  zip_dir(inner_staging, inner_cap)

  # Envelope + ciphertext
  cipher = OpenSSL::Cipher.new('aes-256-gcm')
  cipher.encrypt
  dek = cipher.random_key
  iv = cipher.random_iv
  ciphertext = cipher.update(File.binread(inner_cap)) + cipher.final
  envelope = {
    encryption: {
      algorithm: 'AES-256-GCM',
      keyManagement: 'RSA-OAEP-SHA256',
      encryptedDek: Base64.strict_encode64(public_key.encrypt(dek, RSA_OPTIONS)),
      iv: Base64.strict_encode64(iv),
      authTag: Base64.strict_encode64(cipher.auth_tag)
    }
  }

  # Outer package
  FileUtils.rm_rf(outer_staging)
  FileUtils.mkdir_p(outer_staging)
  FileUtils.cp(File.join(inner_staging, 'metadata.json'), outer_staging)
  File.write(File.join(outer_staging, 'signature.json'),
             JSON.pretty_generate(envelope))
  File.binwrite(File.join(outer_staging, 'package.enc'), ciphertext)
  zip_dir(outer_staging, out)

  FileUtils.rm_rf(inner_staging)
  FileUtils.rm_rf(outer_staging)
  FileUtils.rm_f(inner_cap)
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

# A second, unrelated key pair: mounting the encrypted package with this
# key must fail the DEK unwrap.
other_key = OpenSSL::PKey::RSA.generate(2048)
File.write(File.join(KEYS_DIR, 'other-private.pem'), other_key.to_pem)
File.write(File.join(KEYS_DIR, 'other-public.pem'), other_key.public_key.to_pem)

build_encrypted('encrypted-sample-1.0.0', signing_key.public_key)

build('layered-sample-1.0.0', with_security: true)

# Composite packages (section 4a): the vendor library lives in the
# package store (two versions; newest satisfying must win), the dependent
# package mounts it.
STORE_DIR = File.join(FIXTURES_DIR, 'store')
build('vendor-core-1.0.0', out_dir: STORE_DIR)
build('vendor-core-1.1.0', out_dir: STORE_DIR)
build('composite-sample-1.0.0')

build('auth-sample-1.0.0')
build('oauth-sample-1.0.0')

# Static registry fixture (registry pull): a directory of .cap files plus
# an index.json (guid -> name + versions -> file/sha256/size). The
# registry-tampered entry deliberately records a wrong sha256 so the
# reactor must reject the install with a checksum mismatch.
REGISTRY_DIR = File.join(FIXTURES_DIR, 'registry')

def registry_entry(cap_path, guid, name, version, sha256: nil)
  {
    guid: guid, name: name, version: version,
    file: File.basename(cap_path),
    sha256: sha256 || Digest::SHA256.file(cap_path).hexdigest,
    size: File.size(cap_path)
  }
end

FileUtils.mkdir_p(REGISTRY_DIR)
build('registry-app-1.0.0', out_dir: REGISTRY_DIR)
build('registry-app-1.1.0', out_dir: REGISTRY_DIR)
build('registry-tampered-1.0.0', out_dir: REGISTRY_DIR)

registry_index = { packages: {} }
[
  registry_entry(File.join(REGISTRY_DIR, 'registry-app-1.0.0.cap'),
                 'capsium://fixtures/registry-app', 'registry-app', '1.0.0'),
  registry_entry(File.join(REGISTRY_DIR, 'registry-app-1.1.0.cap'),
                 'capsium://fixtures/registry-app', 'registry-app', '1.1.0'),
  registry_entry(File.join(REGISTRY_DIR, 'registry-tampered-1.0.0.cap'),
                 'capsium://fixtures/registry-tampered',
                 'registry-tampered', '1.0.0', sha256: '0' * 64)
].each do |entry|
  listing = registry_index[:packages][entry[:guid]] ||= {
    'name' => entry[:name], 'versions' => {}
  }
  listing['versions'][entry[:version]] = {
    'file' => entry[:file], 'sha256' => entry[:sha256], 'size' => entry[:size]
  }
end
File.write(File.join(REGISTRY_DIR, 'index.json'),
           JSON.pretty_generate(registry_index))
puts "built #{File.join(REGISTRY_DIR, 'index.json')}"
