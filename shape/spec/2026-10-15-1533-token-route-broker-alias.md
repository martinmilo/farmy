# Use the documented broker alias in the personal-Git regression

The token-routing regression expected the container name shop-keys as the URL host.
FORMATS.md already specifies the app-network broker alias keys, and the existing route
tests require http://keys:9181/<route>/. Both names identify the same broker; the fixture
must use the documented endpoint instead of inventing a new routing requirement.

Correct only PersonalGitConfigTest's expected token URL to
http://keys:9181/dotfiles/acme/shop.git. Continue asserting the complete rewritten URL,
the preserved read-only personal configuration and precedence over its longer conflicting
rewrite. The production result meets the existing contract; no route rule changes.
