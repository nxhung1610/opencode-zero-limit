# Homebrew cask for opencode-zero-limit (unsigned build).
#
# Usage (until this is submitted to homebrew-cask):
#   brew install --cask ./homebrew/opencode-zero-limit.rb
#
# After each release, update `version` and `sha256` below:
#   sha256 $(curl -sL <dmg-url> | shasum -a 256)
cask "opencode-zero-limit" do
  arch arm: "aarch64", intel: "x64"

  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_AFTER_FIRST_RELEASE"

  url "https://github.com/nxhung1610/opencode-zero-limit/releases/download/v#{version}/opencode-zero-limit_#{version}_#{arch}.dmg"
  name "opencode zero limit"
  desc "Keep opencode CLI on free tier: quota view, multi-account switch, proxy pools"
  homepage "https://github.com/nxhung1610/opencode-zero-limit"

  app "opencode-zero-limit.app"
end
