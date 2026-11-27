# Ada için Homebrew formülü / Homebrew formula for Ada
#   brew tap lonlyexe0/ada https://github.com/lonlyexe0/Ada
#   brew install --HEAD lonlyexe0/ada/ada
class Ada < Formula
  desc "Dynamic Island for the MacBook notch: music, lyrics and Claude Code"
  homepage "https://github.com/lonlyexe0/Ada"
  head "https://github.com/lonlyexe0/Ada.git", branch: "main"

  depends_on macos: :sonoma

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"

    contents = prefix/"Ada.app/Contents"
    (contents/"MacOS").install ".build/release/Ada"
    contents.install "Info.plist"
    # İmzayı uygulama kimliğine bağla: macOS izinleri her güncellemede tekrar sorulmasın.
    # Tie the signature to the bundle id so macOS keeps its permissions across updates.
    system "codesign", "--force", "--sign", "-",
           "--requirements", '=designated => identifier "local.ada.island"',
           prefix/"Ada.app"

    (bin/"ada").write <<~SH
      #!/bin/sh
      # ada "mesaj" -> çentikte mesaj / shows a message on the notch
      # ada --statusline, ada --claude-event ... -> uygulamanın kendi seçenekleri / the app's own flags
      APP="#{opt_prefix}/Ada.app/Contents/MacOS/Ada"
      case "$1" in
        --*) exec "$APP" "$@" ;;
        *) exec "$APP" --say "$@" ;;
      esac
    SH
    (bin/"ada").chmod 0755
  end

  def caveats
    <<~EOS
      Ada.app: #{opt_prefix}/Ada.app

      Copy it to ~/Applications to use it like a normal app (the Claude Code hooks point there):
      Normal bir uygulama gibi kullanmak için ~/Applications'a kopyala (Claude Code kancaları oraya bakar):
        ditto "#{opt_prefix}/Ada.app" ~/Applications/Ada.app && open ~/Applications/Ada.app
    EOS
  end

  test do
    assert_predicate prefix/"Ada.app/Contents/MacOS/Ada", :executable?
    assert_match "Ada", pipe_output("#{bin}/ada --statusline", "{}")
  end
end
