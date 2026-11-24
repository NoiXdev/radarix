# Security policy

## Reporting a vulnerability

Use GitHub's private reporting: open the
[Security tab](https://github.com/NoiXdev/radarix/security) of this
repository and choose **Report a vulnerability**. Please do not open a
public issue for anything you believe is a security problem. The issue
tracker is public from the moment you press the button.

Include whatever you have: what you did, what happened, and which version
you were running (Radarix → About Radarix). A proof of concept helps, and
so does an explanation of what an attacker gains. A report you are unsure
about is still worth sending.

**Do not include credentials.** Not yours, not a test account's. If a
token is part of the reproduction, describe its role and leave the value
out.

## What is in scope

Radarix holds access to your GitHub repositories, so the interesting
surface is mostly about that:

- **Stored credentials.** Tokens live only in the macOS Keychain. A path
  that writes a token into a file, a log, an error message or the widget's
  data is a bug worth reporting.
- **Sign-in.** Anything that leaks, misdirects or downgrades the sign-in
  with GitHub.
- **Network traffic.** Radarix talks only to GitHub. A request to any other
  host is in scope.
- **Update checks**, and anything that could turn one into code execution.

## What is not

- Anything that needs an attacker to already have local access to the Mac
  with your account unlocked. The Keychain is the boundary there, and it is
  the system's.
- Problems in GitHub itself.
- Results from automated scanners with no reproduction attached.

## Which versions

The latest release. There are no maintenance branches. A fix ships in the
next release. The current release is on the
[releases page](https://github.com/NoiXdev/radarix/releases/latest).

## What happens next

You will get a reply. If the report is a vulnerability, it is fixed and the
release notes say what changed. You will be credited by whatever name you
ask for, or not at all. If it turns out not to be one, you get the
reasoning rather than silence.
