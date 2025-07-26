# Contributing to Zune

This document will guide you through the process of contributing to our project.

## Table of Contents

1. [How to Contribute](#how-to-contribute)
2. [Development Environment](#development-environment)
3. [Submitting a PR](#submitting-changes)
4. [Thank you](#thank-you-for-contributing)

## How to Contribute

We encourage you to contribute in the following ways:

- **Reporting Issues:** If you find a bug or have a feature request, please [open an issue](https://github.com/Scythe-Technology/zune/issues). 
  - **Bugs**: Provide as much detail as needed to help us understand and reproduce the problem.
- **Submitting Pull Requests (PRs):** If you have code changes or improvements, please submit a pull request. Ensure that your code follows our coding standards and includes appropriate tests. We are most likely going to not accept any PRs to cosmetic, style or non-functional changes.

## Development Environment

To get started, follow these steps to set up your environment:

1. Clone the repository:
```sh
git clone https://github.com/Scythe-Technology/zune.git
cd zune
```
2. Install Zig: Ensure you have Zig installed. You can download it from the [official Zig website.](https://ziglang.org/)
3. Build the Project:
```sh
zig build
```
4. Run tests:
```sh
zig build test
```
5. Formatting:
```sh
zig fmt [file]
# or any other tools, ideally it just needs to be zig formatted.
# and should pass CI.
```
6. Code Style: *N/A (Undecided)*.

## Submitting a PR
When submitting a PR, please provide as much detail as possible for the changes when making feature additions. For **bug fixes** or **minor changes**, a brief description is sufficient or use `Fixes #<issue number>` or `Closes #<issue number>` in the PR description of the issue the **bug fix** is related to.

## Thank you for contributing!
If you have any questions or need help, join the [Sythivorium](https://discord.gg/zEc7muuYbX) server and ask in `#zune` channel.
