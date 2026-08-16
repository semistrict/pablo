#!/usr/bin/env ruby

require "json"
require "fileutils"
require "yaml"

project_directory = File.expand_path("..", __dir__)
source_path = File.join(project_directory, "api", "control-api.openapi.yaml")
output_directory = File.join(project_directory, "Sources", "Pablo", "Resources")
output_path = File.join(output_directory, "control-api.openapi.json")

document = YAML.safe_load(File.read(source_path), [], [], false)
generated = JSON.pretty_generate(document) + "\n"
FileUtils.mkdir_p(output_directory) unless Dir.exist?(output_directory)
if ARGV == ["--check"]
  abort "Run scripts/generate-control-openapi.rb to refresh #{output_path}." unless
    File.exist?(output_path) && File.read(output_path) == generated
else
  File.write(output_path, generated)
end
