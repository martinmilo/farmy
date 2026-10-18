# Comparing a whole text with the one the spec lays out: a screen, a generated file.
#
# The failure shows the text itself, line by line, so that it can be read and copied:
# quotes are not escaped, and a tab, which would be invisible, is drawn as →. Each line is
# labelled in words, because the texts themselves contain lines that start with + and -.
require "open3"
require "tempfile"

module ExactText
  LABELS = { "-" => "missing  | ", "+" => "remove   | ", " " => "         | " }.freeze

  def assert_same_text(expected, actual, what, after: "")
    tabs = " A tab character is drawn as →." if "#{expected}#{actual}".include?("\t")
    assert expected == actual, "#{what} is not what was expected. Below is the expected text; a line marked \"missing\" " \
                               "is not there, and a line marked \"remove\" is there and should not be.#{tabs}\n\n" \
                               "#{line_by_line(expected, actual)}#{after}"
  end

  private

  def line_by_line(expected, actual)
    files = [expected, actual].map do |text|
      Tempfile.new("text").tap { |file| file.write(text.gsub("\t", "→")); file.close }
    end
    output, = Open3.capture2("diff", "-U", "100000", *files.map(&:path))
    output.lines.drop(3).map { |line| line.start_with?("\\") ? "  (#{line[2..].chomp})\n" : "  #{LABELS.fetch(line[0])}#{line[1..]}" }.join.chomp
  ensure
    files&.each(&:unlink)
  end
end
