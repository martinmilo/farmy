# Private logins and shared tool data

The approved toolbox review allows shared dotfiles and named tool data when shared_logins is false,
provided no shared login directories are exposed. The earlier toolbox record identified the old
MountsTest assertion forbidding every farmy-shared mount as incompatible with this decision.

The MountsTest scenario now checks the intended boundary: any farmy-shared mounts expose only
dotfiles/tool-data subpaths, while agent logins remain on the service's own volume and retain its
private FARMY_LOGIN_DIR. The separate SharedToolDataTest proves that nvim data and read-only dotfiles
are actually usable with private logins. The real-container login-path integration assertion remains
unchanged. This completes the previously approved existing-test adjustment; it adds no new decision.
