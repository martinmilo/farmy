# Inputs live in test/fixtures, expected outputs in test/expected.
# Both are written by hand from the spec. Never record them from the program.
module Fixtures
  def fixture(path)  = File.read(File.join(TEST_ROOT, "fixtures", path))
  def expected(path) = File.read(File.join(TEST_ROOT, "expected", path))
end
