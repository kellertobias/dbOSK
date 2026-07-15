# Homebrew formula for dbosk. This repo doubles as its own tap:
#
#   brew tap kellertobias/dbosk https://github.com/kellertobias/dbosk
#   brew install --HEAD dbosk
#
class Dbosk < Formula
  desc "Native macOS database client for PostgreSQL, MySQL/MariaDB, MongoDB, and SQLite"
  homepage "https://github.com/kellertobias/dbosk"
  head "https://github.com/kellertobias/dbosk.git", branch: "main"

  # Once a release tag is pushed (git tag v0.1.0 && git push origin v0.1.0),
  # enable plain `brew install dbosk` by adding a stable spec above `head`:
  #
  #   url "https://github.com/kellertobias/dbosk/archive/refs/tags/v0.1.0.tar.gz"
  #   sha256 "<output of: curl -sL <url> | shasum -a 256>"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma

  def install
    # SwiftPM's own sandbox conflicts with Homebrew's build sandbox.
    ENV["DBOSK_SWIFT_BUILD_FLAGS"] = "--disable-sandbox"
    ENV["DBOSK_VERSION"] = version.to_s unless build.head?
    system "Scripts/make-app.sh"
    prefix.install "dist/Dbosk.app"
    (bin/"dbosk").write_exec_script prefix/"Dbosk.app/Contents/MacOS/Dbosk"
  end

  def caveats
    <<~EOS
      Dbosk.app is installed to:
        #{opt_prefix}/Dbosk.app

      To show it in Launchpad and Spotlight, link it into /Applications:
        ln -sf "#{opt_prefix}/Dbosk.app" /Applications/Dbosk.app

      The app was compiled locally and is ad-hoc signed. Because it was
      built on this machine (not downloaded), it carries no quarantine
      attribute and launches without a Gatekeeper prompt.
    EOS
  end

  test do
    assert_path_exists prefix/"Dbosk.app/Contents/MacOS/Dbosk"
    system "/usr/bin/codesign", "--verify", prefix/"Dbosk.app"
  end
end
