# Contributing to swift-vroid-sdk

Thank you for your interest in swift-vroid-sdk. This project is maintained by a single person with limited time for review. The rules below exist so that contributions can be reviewed and merged reliably within that time. Pull requests that do not follow them may be closed regardless of their content.

## Discuss large changes in an issue first

Unless your change is a bug fix, a typo fix in the documentation, or a minor suggestion, open an issue and agree on the approach before writing a pull request. The following always require prior discussion:

- New features or endpoints, or additions or changes to the public API
- Changes to sign-in, token storage, or the encrypted model cache
- Changes to dependencies, supported OS versions, or the Swift version
- Changes to the directory layout or build configuration

If a large pull request arrives without prior discussion and its design does not match the direction of the project, none of it can be accepted. Reach agreement in an issue before you start implementing.

## One pull request, one purpose

- Solve exactly one problem per pull request. Put "while I was at it" changes in separate pull requests
- Keep the change under 300 lines as a guideline, and under 500 lines at most. If it has to be larger, propose how to split it in an issue first
- Pull requests that bundle several changes, bring over the state of a fork as is, or resolve several issues at once will not be accepted
- Keep refactoring separate from feature work

## Checklist before opening a pull request

- [ ] The description links the related issue (for example `Closes #123`)
- [ ] The change has a single, focused purpose
- [ ] The branch is rebased on the latest `main`
- [ ] `swift test` passes
- [ ] The iOS build passes
- [ ] Tests covering the changed behavior are added or updated
- [ ] No new compiler warnings are introduced
- [ ] No unrelated files are included (`.gitignore`, formatting-only diffs, generated files, and so on)
- [ ] No credentials, tokens, or model files are included
- [ ] The README is updated if the public API changed

## Code

- Match the style, naming, and comment density of the surrounding code
- Write comments only where they explain why something is done. Comments that describe what the code does, or what was changed, are not needed
- Do not leave commented-out code behind
- Never treat a condition of use that is unset or unknown as a permission. Wording shown to users is the application's responsibility; keep it out of the SDK

## VRoid Hub API behavior

If a change relies on how the VRoid Hub API responds (field shapes, pagination, error codes, and so on), describe in the pull request how you confirmed that behavior. Do not include real responses that contain personal data, and never commit your application's client secret, `credential.json.bytes`, access tokens, or downloaded model files.

## Testing

- macOS: `swift test`
- iOS: `xcodebuild -scheme swift-vroid-sdk-Package -destination "generic/platform=iOS Simulator" build`

Tests must run without network access or VRoid Hub credentials; use the mock transport in `Tests/VRoidSDKTests/Support`. CI runs the tests on macOS and builds for iOS once the maintainer approves the workflow run. Pull requests with failing CI will not be reviewed.

## Changes made with AI tools

Using AI tools is not prohibited, but the following applies:

- Before submitting, read, understand, and verify every line of the change yourself. Do not submit changes you cannot explain
- Do not submit large AI-generated changes as they are. The size and scope limits above apply unchanged
- Claims such as "tested" or "verified" in the pull request description must describe what you actually did yourself
- If you used an AI tool, mention it in the pull request description or in a commit trailer. This is not required, but it helps the review

## Review

- Review can take time. Please refrain from posting reminders while waiting for a reply
- A change may be declined because it does not fit the direction of the project, or because its maintenance cost outweighs its benefit
- Pull requests that receive no reply or update for an extended period will be closed

## License

By contributing, you agree that your contribution is released under the project's [license](./LICENSE).
