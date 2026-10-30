# The README starts a stranger with no setup: install, farmy add, farmy; and says where farmy keeps things.
# Record 2026-10-29-0926.
class ReadmeDefaultHomeTest < AcceptanceTest
  test "the README's first service is three lines, the installer, farmy add and farmy, and no command in it makes or enters a containers folder" do
    assert_readme_quick_start_is_three_lines
    refute_readme_code(/\bmkdir\b/, "make a folder (mkdir)")
    refute_readme_code(/(?:\A|&&|;)\s*cd\s/, "enter a folder (cd)")
  end

  test "the README's section Where farmy keeps things names both default paths, the project folder found by farmy.yml, -C, FARMY_DIR and git clone" do
    assert_readme_section_says "Where farmy keeps things", "~/.config/farmy", "~/.local/state/farmy", "farmy.yml", "-C", "FARMY_DIR", "git clone"
  end

  test "getting started says where farmy keeps things and has the reader make no containers folder" do
    assert_guide_says "docs/getting-started.md", "~/.config/farmy"
    refute_guide_says "docs/getting-started.md", "mkdir ~/containers"
  end
end
