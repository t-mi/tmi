# frozen_string_literal: true

require 'base64'
require 'changelogerator'
require 'erb'
require 'git'
require 'json'
require 'octokit'
require 'toml'
require_relative './lib.rb'

current_ref = ENV['GITHUB_REF']
token = ENV['GITHUB_TOKEN']
github_client = Octokit::Client.new(
  access_token: token
)

tmi_path = ENV['GITHUB_WORKSPACE'] + '/tmi/'

# Generate an ERB renderer based on the template .erb file
renderer = ERB.new(
  File.read(ENV['GITHUB_WORKSPACE'] + '/tmi/scripts/github/tmi_release.erb'),
  trim_mode: '<>'
)

# get ref of last tmi release
last_ref = 'refs/tags/' + github_client.latest_release(ENV['GITHUB_REPOSITORY']).tag_name

tmi_cl = Changelog.new(
  'tmi/tmi', last_ref, current_ref, token: token
)

# Gets the substrate commit hash used for a given tmi ref
def get_substrate_commit(client, ref)
  cargo = TOML::Parser.new(
    Base64.decode64(
      client.contents(
        ENV['GITHUB_REPOSITORY'],
        path: 'Cargo.lock',
        query: { ref: ref.to_s }
      ).content
    )
  ).parsed
  cargo['package'].find { |p| p['name'] == 'sc-cli' }['source'].split('#').last
end

substrate_prev_sha = get_substrate_commit(github_client, last_ref)
substrate_cur_sha = get_substrate_commit(github_client, current_ref)

substrate_cl = Changelog.new(
  'tmi/substrate', substrate_prev_sha, substrate_cur_sha,
  token: token,
  prefix: true
)

# Combine all changes into a single array and filter out companions
all_changes = (tmi_cl.changes + substrate_cl.changes).reject do |c|
  c[:title] =~ /[Cc]ompanion/
end

# Set all the variables needed for a release

misc_changes = Changelog.changes_with_label(all_changes, 'B1-releasenotes')
client_changes = Changelog.changes_with_label(all_changes, 'B5-clientnoteworthy')
runtime_changes = Changelog.changes_with_label(all_changes, 'B7-runtimenoteworthy')

# Add the audit status for runtime changes
runtime_changes.each do |c|
  if c.labels.any? { |l| l[:name] == 'D1-audited👍' }
    c[:pretty_title] = "✅ `audited` #{c[:pretty_title]}"
    next
  end
  if c.labels.any? { |l| l[:name] == 'D9-needsaudit👮' }
    c[:pretty_title] = "❌ `AWAITING AUDIT` #{c[:pretty_title]}"
    next
  end
  if c.labels.any? { |l| l[:name] == 'D5-nicetohaveaudit⚠️' }
    c[:pretty_title] = "⏳ `pending non-critical audit` #{c[:pretty_title]}"
    next
  end
  c[:pretty_title] = "✅ `trivial` #{c[:pretty_title]}"
end

# The priority of users upgraded is determined by the highest-priority
# *Client* change
release_priority = Changelog.highest_priority_for_changes(client_changes)

# Pulled from the previous Github step
rustc_stable = ENV['RUSTC_STABLE']
rustc_nightly = ENV['RUSTC_NIGHTLY']
tmi_runtime = get_runtime('tmi', tmi_path)
kusama_runtime = get_runtime('kusama', tmi_path)
westend_runtime = get_runtime('westend', tmi_path)

# These json files should have been downloaded as part of the build-runtimes
# github action

tmi_json = JSON.parse(
  File.read(
    ENV['GITHUB_WORKSPACE'] + '/tmi-srtool-json/srtool_output.json'
  )
)

kusama_json = JSON.parse(
  File.read(
    ENV['GITHUB_WORKSPACE'] + '/kusama-srtool-json/srtool_output.json'
  )
)

puts renderer.result
