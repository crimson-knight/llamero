#!/usr/bin/env ruby
# frozen_string_literal: true

# Low-info issue triage. Ruby stdlib only — no gems.
#
# Flags issues whose body is essentially just a pasted error (little/no prose),
# labels them `needs-info`, posts one courteous comment, and closes them
# (`not_planned`). When the author edits the issue and it clears the bar, it is
# reopened automatically — no maintainer in the loop.
#
# Env: GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_EVENT_PATH (standard Actions env)
#      MIN_PROSE_WORDS (default 12), DRY_RUN ("true" = label only, never close)

require "json"
require "net/http"
require "uri"

MARKER = "<!-- low-info-triage -->"
MIN_PROSE_WORDS = (ENV["MIN_PROSE_WORDS"] || "12").to_i
DRY_RUN = ENV["DRY_RUN"] == "true"
EXEMPT_ASSOCIATIONS = %w[OWNER MEMBER COLLABORATOR].freeze
EXEMPT_LABELS = %w[confirmed triaged].freeze

event = JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH")))
issue = event.fetch("issue")
action = event.fetch("action")
repo = ENV.fetch("GITHUB_REPOSITORY")
number = issue.fetch("number")

def api(method, path, body = nil)
  uri = URI("https://api.github.com#{path}")
  req = case method
        when :get then Net::HTTP::Get.new(uri)
        when :post then Net::HTTP::Post.new(uri)
        when :patch then Net::HTTP::Patch.new(uri)
        when :delete then Net::HTTP::Delete.new(uri)
        end
  req["Authorization"] = "Bearer #{ENV.fetch("GITHUB_TOKEN")}"
  req["Accept"] = "application/vnd.github+json"
  req.body = body.to_json if body
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  abort "GitHub API #{method} #{path} failed: #{res.code} #{res.body[0, 300]}" unless res.code.to_i < 300
  res.body.empty? ? nil : JSON.parse(res.body)
end

# Prose = what's left after removing everything that reads as pasted output.
def prose_word_count(body)
  return 0 if body.nil?
  text = body.dup
  text.gsub!(/```.*?```/m, " ")               # fenced code blocks
  text.gsub!(/`[^`]*`/, " ")                  # inline code
  text = text.lines.reject do |line|
    line.start_with?(">") ||                  # quotes
      line.match?(/^\s*(at |from |#\d+ |\S+\.(cr|rb|swift|py|js|ts):\d+)/) || # stack frames
      line.match?(/^\s*[\w.\/-]+error[: ]/i) ||
      line.match?(/^### /)                    # issue-form section headers
  end.join(" ")
  # Drop issue-form boilerplate labels so an untouched template doesn't count as prose.
  %w[_No\ response_ What\ were\ you\ doing? Expected\ result Actual\ result Environment Model\ id].each { |b| text.gsub!(b, " ") }
  text.split(/\s+/).count { |w| w.match?(/[a-zA-Z]{2,}/) }
end

labels = issue.fetch("labels", []).map { |l| l["name"] }
if EXEMPT_ASSOCIATIONS.include?(issue["author_association"]) || (labels & EXEMPT_LABELS).any?
  puts "exempt (author #{issue["author_association"]}, labels #{labels.join(",")}) — skipping"
  exit 0
end

words = prose_word_count(issue["body"])
low_info = words < MIN_PROSE_WORDS
puts "issue ##{number} action=#{action} prose_words=#{words} low_info=#{low_info} dry_run=#{DRY_RUN}"

already_flagged = labels.include?("needs-info")
bot_commented = api(:get, "/repos/#{repo}/issues/#{number}/comments?per_page=100")
  .any? { |c| c["body"].to_s.include?(MARKER) }

if low_info && !already_flagged
  api(:post, "/repos/#{repo}/issues/#{number}/labels", { labels: ["needs-info"] })
  api(:delete, "/repos/#{repo}/issues/#{number}/labels/needs-triage") if labels.include?("needs-triage")
  unless bot_commented
    api(:post, "/repos/#{repo}/issues/#{number}/comments", { body: <<~MSG })
      #{MARKER}
      Thanks for filing this. To reproduce it we need a bit more than the error text — what you were running, the model id, what you expected to happen, and your environment (llamero version/commit, OS/chip, whether you built the native bridge).

      Edit this issue to add those details and it will reopen automatically. The bug-report form has all the fields if that's easier.
    MSG
  end
  unless DRY_RUN
    api(:patch, "/repos/#{repo}/issues/#{number}", { state: "closed", state_reason: "not_planned" })
    puts "closed as needs-info"
  end
elsif !low_info && already_flagged && action == "edited"
  api(:delete, "/repos/#{repo}/issues/#{number}/labels/needs-info")
  api(:post, "/repos/#{repo}/issues/#{number}/labels", { labels: ["needs-triage"] })
  api(:patch, "/repos/#{repo}/issues/#{number}", { state: "open" }) if issue["state"] == "closed"
  api(:post, "/repos/#{repo}/issues/#{number}/comments", { body: "#{MARKER}\nThanks — reopened, we'll take a look." })
  puts "reopened after edit"
else
  puts "no action needed"
end
