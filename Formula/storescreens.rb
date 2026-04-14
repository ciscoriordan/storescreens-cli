class Storescreens < Formula
  desc "Capture iOS simulator screenshots for every App Store device size"
  homepage "https://github.com/ciscoriordan/storescreens-cli"
  url "https://github.com/ciscoriordan/storescreens-cli/releases/download/v1.0.0/storescreens-v1.0.0-macos.tar.gz"
  sha256 "PLACEHOLDER_SHA256"
  license "MIT"

  def install
    bin.install "storescreens"
  end

  test do
    assert_match "USAGE: storescreens", shell_output("#{bin}/storescreens --help", 0)
  end
end
