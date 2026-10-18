# Writing tests

A test in this project has two readers.

- **The owner**, who reviews it. A test should read like the sentence in the spec it came
  from, so that a wrong test is obvious at a glance.
- **The worker**, who never sees it. It sees the test's name and what the test prints
  when it fails, and builds the program from that alone.

Readability is what this whole setup exists for. A test file contains behaviour and nothing
else. Everything mechanical lives in `test/support/`.

Sections 1 to 8 are the rules. Section 9 shows each of them in a good and a bad example.
Read the whole file before writing a test. The examples use an imaginary product, a
command-line tool for a gift-voucher shop, so that nothing in them can be mistaken for this
project's spec.

## 1. The approach

Tests come first and they describe behaviour from outside. That takes the order from TDD
(write the test, watch it fail, then the code gets written) and the level from BDD (what a
user can observe, in the words the spec uses). It takes the tooling from neither: plain
Minitest, no Gherkin, no step definitions, no spec DSL. A second layer of files that maps
sentences to code is plumbing, and plumbing is what we are removing.

Tests run the built program the way a user would: a command, in a folder, with files. The
kit is for command-line programs; a service would need helpers of its own. They
never load its code, call its functions or read its private state. That is what lets the
implementation change completely underneath them.

Unit-level red-green-refactor is the worker's business, inside its own folder.

## 2. Choosing which tests to write

Start from the scenario list in the spec record. For each behaviour, ask these in order and
write one test per answer:

1. **What does success look like, and what does it leave behind?**
2. **What can refuse it?** One test per rule. Each asserts the reason, and that the refusal
   left nothing behind.
3. **Where are the limits?** For each limit, the last value that is allowed and the first
   that is not.
4. **What if it happens twice?**
5. **Which starting states change the answer?** One test per state that does.
6. **What about none?** No items, a missing optional input, an empty file.
7. **What must never happen?** An overwrite, a partial write, a file touched that should
   have been left alone.

Then stop. Leave out random or fuzzed input, malformed bytes, races, load, and every
combination of options that do not interact, unless a spec record asks for them.

The test for a test: you can point at the sentence in a spec record that it protects. If
you cannot, either the spec is missing a sentence (raise it) or the test is not needed.

## 3. What to assert

Assert what the behaviour promises, and nothing the program is free to change.

| Assert | Leave alone |
|---|---|
| the exit code | how long it took |
| the part of stdout that carries the answer | the rest of the line, unless the spec fixes it |
| the part of stderr that names the reason | the exact wording of the message, unless the spec fixes it |
| files the command exists to produce, and that it wrote nothing else | files the program keeps for its own use |

Three rules follow.

- **A refusal asserts its reason.** An exit code alone passes when the program refuses for
  the wrong reason.
- **Exact, whole-output comparison is for output whose layout is the feature**: a rendered
  view, a generated file. Everything else is asserted by the piece that matters.
- **Observe through the interface a user has.** If `list` shows that a voucher is redeemed,
  do not open the file the program stores it in. Read a file only when the file is the
  product.

## 4. How a test reads

```ruby
class RedeemVoucherTest < AcceptanceTest
  def setup = workspace("shop") # GIFT-2041 is active, GIFT-1187 is redeemed; both valid until 2026-12-31

  test "a redeemed voucher cannot be redeemed again" do
    redeem "GIFT-1187"

    assert_exit 1
    assert_stderr "already redeemed"
    assert_nothing_written
  end
end
```

- **The name is a sentence: a situation and its outcome.** It is the first thing the
  worker reads. Avoid "works", "correctly", "handles", "should".
- **Three parts, separated by blank lines:** the situation, the action, the outcome. Leave a
  part out when it is empty.
- **About eight lines at most.** When a test needs more, something is missing: a fixture,
  or a word in the vocabulary.
- **One behaviour per test.** Several assertions are fine when together they describe one
  outcome.
- **No plumbing.** A test file has no `require`, and no `Open3`, `JSON`, `YAML`, `File`,
  `Dir` or `ENV`. If you need one of them, a helper is missing.
- **No logic.** No `if`, no `rescue`, no loops inside a test. The one exception is the table
  in section 9.3.
- **Expected values are written out.** Never compute them, and never read them from the
  same fixture the program reads. The reader should see the expected value on the line.
- **Realistic data.** Emma Clarke with a 50 € voucher, never `foo`, `test@test.com` or
  `Company A`. Show only the values the behaviour depends on; give the rest defaults in a
  helper.
- **`setup` is for one line** that states the starting situation every test in the class
  shares. Say in a comment what in the fixture matters, so nobody has to open it.
- **Each test stands alone.** It gets its own empty folder and creates what it needs. The
  suite runs in random order.

### Where things go

```
test/
  test_helper.rb        project settings and the base class
  run.rb                what bin/verify calls; picks the test files this branch adds or changes
  support/              every helper; the only place plumbing is allowed
  fixtures/             inputs. workspaces/<name>/ is a starting folder; other files are loose
  expected/             exact outputs, written by hand from the spec
  <area>/<behaviour>_test.rb    one class per file, one behaviour per class
```

A test file is loaded by `run.rb`, which is why it needs no `require`; it cannot be run on
its own. Put a value inline when it is up to three lines and the test is about it. Otherwise it
goes in a file. Keep a few well-known fixture workspaces and reuse them; twenty near-copies
are harder to read than three.

**Expected files are written by hand from the spec.** Never run the program and save what
it printed. That records what the program does, and the test is there to say what it
should do.

### Growing the vocabulary

Add a helper when the same lines appear in a third test, or when a line is not about the
behaviour under test. Name it for what it means (`redeem`), not for what it does
(`run_with_date_env`). Put it in a module in `test/support/` and add the module to the
`include` line in `test_helper.rb`.

```ruby
module Vouchers
  # The clock is always pinned, so a test never changes its answer as real time passes.
  def redeem(code, on: "2026-10-09")
    cli "redeem", code, env: { "VOUCHERS_TODAY" => on }
  end

  def issue(amount, to: "emma.clarke@example.com")
    cli "issue", amount, "--to", to
  end
end
```

A helper may check that its own setup worked. It never hides the action or the assertion
the test is about; those stay visible in the test.

## 5. The vocabulary you start with

| To | Write |
|---|---|
| start from a prepared folder | `workspace "shop"` |
| start from a prepared Git repository | `workspace "shop", git: true` (the fixture, committed once) |
| give the folder a name, when the behaviour reads it | `folder_named "shop"` (first line of the test) |
| make any folder a Git repository | `start_repository` (commits the folder as it is now) |
| change that folder | `write_file path, text` · `write_executable path, text` · `edit_file path` · `delete_file path` |
| use Git in it | `git "add", "vouchers"` · `commit "Redeem GIFT-2041"` (stages everything, then commits) · `commit "Redeem GIFT-2041", on: "2026-10-05"` (with that commit date) · `branch "refunds"` · `switch_to "main"` · `merge "refunds"` (a side branch, merged back) |
| run the program | `cli "redeem", "GIFT-2041"` (options: `stdin: "text"`, `env: { "NAME" => "value" }`) |
| run another executable from the work folder | `script "bin/backup", "data"` |
| check how it ended | `assert_success` · `assert_failure` · `assert_exit 2` |
| check what it printed | `assert_stdout "text"` · `assert_stderr /pattern/` · `refute_stdout "text"` · `refute_stderr "text"` |
| check the whole output | `assert_stdout_is expected("list_shop.txt")` |
| check the shape of a screen | `assert_lines_within 80` (every line fits) · `assert_stdout_lines 3` (exactly that many) |
| say in a failure what a helper set up | `note_situation "GIFT-2041 is a 50 € voucher"` (shown under the transcript; for helpers, not tests) |
| check files | `assert_file path` · `assert_file path, includes: "text"` · `assert_file path, is: expected("file")` · `refute_file path` |
| check nothing else changed | `assert_nothing_written` · `assert_unchanged path` · `assert_written_only path` (all compare with the moment before the last command) |
| read test data | `fixture("vouchers/GIFT-3050.json")` · `expected("list_shop.txt")` · `stdout` · `stderr` · `read_file path` |

Every command runs inside the test's own folder. Without `workspace`, that folder is empty.
An executable in a fixture workspace is still executable in the test's copy.

## 6. Time, generated values and state

- **Pin the clock** in every test whose answer depends on the date. Put the default in the
  helper, as `redeem` does above.
- **Generated values** (codes, ids) are matched by pattern, never hard-coded.
- **A fixture used for a refusal breaks exactly one rule,** and the test asserts which. A
  voucher that is both redeemed and expired keeps a test green when either check is broken.
- **Git is deterministic.** `workspace ..., git: true` and `commit` use a fixed author and
  date and ignore the machine's Git configuration. The program runs with the same settings.
  When the answer depends on when a commit was made, give the commit a date:
  `commit "...", on:` takes a day or a full timestamp. A failure in a Git workspace prints
  the commits and what is uncommitted under the transcript.

## 7. What you may ask of the program

Testing from outside sometimes needs a handle that a normal user would not use: a way to
set today's date, to turn colour off, to fix the output width. Ask for it. It is behaviour
like any other: agree it with the owner, write it into the spec record, and cover it with a
test. Prefer an environment variable or an option over anything cleverer.

When the program runs another program, the tests replace that one with a small fake: an
executable kept in the fixture workspace that prints fixed output, with one fake per
situation worth testing (a good answer, a malformed one, a non-zero exit). The program is
pointed at the fake through its normal configuration. Nothing is ever stubbed inside the
program.

## 8. Before you hand off

Run `ruby test/run.rb` and go through this list.

- Every new test fails, and for the reason its name gives.
- Each failure can be understood by someone who has never seen the test. This is what the
  worker gets:

  ```
    1) Failure:
  RedeemVoucherTest#test_a_redeemed_voucher_cannot_be_redeemed_again [test/vouchers/redeem_test.rb:16]:
  Expected exit 1, got 0.

    $ VOUCHERS_TODAY=2026-10-09 vouchers redeem GIFT-1187
    exit 0
    stdout:
      Redeemed GIFT-1187 (120 €)
    stderr: (empty)
  ```

  The name says what should happen, the transcript says what did. If a failure of yours
  needs the test body to make sense, rename the test or improve the helper's message.
- Read the names of the new tests in a row (`ruby test/run.rb -v`). They should read as a
  description of the feature.
- No test file contains plumbing, logic or a computed expectation.
- Every refusal asserts its reason and what was left behind.
- Nothing depends on today's date, on test order, or on another test's data.
- Tests that already passed still pass (`ruby test/run.rb --all`).

## 9. Examples

### 9.1 A command

Good:

```ruby
test "an active voucher is redeemed" do
  redeem "GIFT-2041"
  assert_success
  assert_stdout "Redeemed GIFT-2041 (50 €)"

  cli "list"
  assert_stdout(/GIFT-2041 .+ redeemed/)
end

test "an unknown code is reported as a mistake in the command" do
  redeem "GIFT-0000"

  assert_exit 2
  assert_stderr "GIFT-0000"
  assert_nothing_written
end
```

Bad:

```ruby
def test_redeem
  Dir.mktmpdir do |dir|
    FileUtils.cp_r("test/fixtures/workspaces/shop/.", dir)
    out, err, status = Open3.capture3("#{ENV["SUT_ROOT"]}/bin/vouchers", "redeem", "GIFT-2041", chdir: dir)
    assert status.success?
    voucher = JSON.parse(File.read("#{dir}/vouchers/GIFT-2041.json"))
    assert_equal "redeemed", voucher["status"]
    assert_equal "Redeemed #{voucher["code"]} (#{voucher["amount"]} €)\n", out
  end
end
```

Half of it is plumbing. The name says nothing. It reads the program's private storage when
`list` would show the same thing. The expected text is assembled from the data under test,
so the reader cannot see what is expected. And it checks the whole line including the
newline, where the spec only promised the content.

### 9.2 Business rules

A rule is tested through the interface, at its edges, with the clock pinned.

Good:

```ruby
test "a voucher can still be redeemed on its last valid day" do
  redeem "GIFT-2041", on: "2026-12-31"

  assert_success
end

test "a voucher is refused the day after it expires" do
  redeem "GIFT-2041", on: "2027-01-01"

  assert_exit 1
  assert_stderr "expired on 2026-12-31"
  assert_nothing_written
end
```

Bad:

```ruby
test "expiry works" do
  cli "redeem", "GIFT-0031" # expired last August, and already redeemed

  assert_failure
end
```

Three problems, and the last two are easy to miss. The name does not say what should
happen. The test depends on today's date, so its answer changes as time passes. And it
passes for the wrong reason: GIFT-0031 is both redeemed and expired, so either rule can be
broken and the test stays green.

### 9.3 The same rule, several values

When cases differ only in their data, a small table is clearer than four copies. Each row
must produce a full sentence as its test name.

```ruby
{ 9 => "at least 10", 501 => "at most 500" }.each do |amount, limit|
  test "issuing a voucher for #{amount} € is refused because the amount must be #{limit}" do
    issue amount

    assert_exit 1
    assert_stderr limit
    assert_nothing_written
  end
end

[10, 500].each do |amount|
  test "issuing a voucher for #{amount} € is accepted" do
    issue amount

    assert_success
  end
end
```

Use this for limits and equivalent inputs only. If the rows need different steps or
different assertions, they are different tests.

### 9.4 A command inside a Git repository

Good:

```ruby
class ChangedVouchersTest < AcceptanceTest
  def setup = workspace("shop", git: true) # GIFT-2041 and GIFT-1187, committed

  test "a voucher edited since the last commit is reported" do
    redeem "GIFT-2041"

    cli "changed"

    assert_stdout "GIFT-2041"
    refute_stdout "GIFT-1187"
  end

  test "a staged edit is still reported" do
    redeem "GIFT-2041"
    git "add", "vouchers"

    cli "changed"

    assert_stdout "GIFT-2041"
  end

  test "a voucher file Git does not track yet is reported" do
    write_file "vouchers/GIFT-3050.json", fixture("vouchers/GIFT-3050.json")

    cli "changed"

    assert_stdout "GIFT-3050"
  end

  test "a committed edit is no longer reported" do
    redeem "GIFT-2041"
    commit "Redeem GIFT-2041"

    cli "changed"

    assert_stdout "No vouchers changed."
  end

  test "a change to an unrelated file reports nothing" do
    write_file "data/customers.csv", "id,name\n1,Emma Clarke\n"

    cli "changed"

    assert_stdout "No vouchers changed."
  end
end
```

Each state Git can be in is its own test, because each needs different steps. The last two
matter as much as the first three: a command that reports everything would pass the others.

Bad:

```ruby
test "changed works with git" do
  redeem "GIFT-2041"
  cli "changed"
  assert_stdout "GIFT-2041"
  git "add", "vouchers"
  cli "changed"
  assert_stdout "GIFT-2041"
  commit "Redeem"
  cli "changed"
  refute_stdout "GIFT-2041"
end
```

Three behaviours in one test. When it fails, the name does not say which one broke, and the
worker has to count commands in the transcript to find out.

### 9.5 Another executable

Good:

```ruby
test "a backup is written as a dated archive" do
  script "bin/backup", "data", env: { "BACKUP_DATE" => "2026-10-09" }

  assert_success
  assert_file "backups/data-2026-10-09.tar.gz"
end

test "backing up a folder that does not exist fails and writes nothing" do
  script "bin/backup", "invoices"

  assert_exit 1
  assert_stderr "no such directory: invoices"
  assert_nothing_written
end
```

Bad:

```ruby
test "backup" do
  script "bin/backup", "data"

  assert_success
end
```

It proves the script exits 0 and nothing about what it did. The archive name contains
today's date, so the test could not check for the file even if it wanted to; that is why
the good version pins the date.

### 9.6 Output whose layout is the feature

```ruby
test "list shows every voucher as an aligned table with a count" do
  workspace "shop"

  cli "list"

  assert_stdout_is expected("list_shop.txt")
end
```

`test/expected/list_shop.txt` is typed out from the spec. On failure the worker gets a
line-by-line diff. Keep these few: each one freezes every character of the output, so use
one per layout the spec defines, and assert the rest by the piece that matters.
