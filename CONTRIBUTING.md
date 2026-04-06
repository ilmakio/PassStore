# Contributing to PassStore

Thank you for your interest in contributing to PassStore! Here's how you can help.

## Reporting Bugs

- Open a [GitHub Issue](../../issues) with a clear description
- Include your macOS version and PassStore version
- Describe what you expected and what happened instead
- Steps to reproduce the issue are very helpful

## Suggesting Features

- Open a [GitHub Issue](../../issues) with the "enhancement" label
- Describe the use case and why it would be useful
- Check existing issues first to avoid duplicates

## Pull Requests

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes
4. Ensure the project builds and tests pass
5. Submit a pull request against `main`

### Code Style

- **Swift 6** with strict concurrency
- **SwiftUI** for all UI
- **MVVM** architecture: respect the existing separation between `Domain/`, `Data/`, and `Presentation/`
- Follow the existing naming conventions and code organization
- Keep PRs focused on a single change

### Testing

- Add unit tests for new logic in `PassStoreTests/`
- Run existing tests before submitting to ensure nothing is broken

## Release & Distribution

Releases and distribution are managed by the project maintainer. If you'd like to distribute a fork, you will need to configure your own code signing and update infrastructure.

## Code of Conduct

Be respectful and constructive. We're all here to build something useful.
