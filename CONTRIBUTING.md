# Contributing to galaxy

Thank you for your interest in contributing to galaxy!

## Development Setup

### Prerequisites

- [Crystal](https://crystal-lang.org/) >= 1.0.0
- Git
- Make

### Getting Started

1. Clone the repository:
   ```bash
   git clone https://github.com/kellyredding/galaxy.git
   cd galaxy
   ```

2. Build and test a tool:
   ```bash
   cd tools/statusline
   make check
   ```

## Project Structure

Each tool lives in its own directory under `tools/`:

```
tools/
└── statusline/
    ├── README.md           # Tool documentation
    ├── LICENSE             # MIT License
    ├── RELEASING.md        # Release process
    ├── VERSION.txt         # Current version
    ├── Makefile            # Build configuration
    ├── shard.yml           # Crystal dependencies
    ├── src/                # Source code
    ├── spec/               # Tests
    └── bin/                # Release scripts
```

## Development Workflow

### Making Changes

1. Create a feature branch:
   ```bash
   git checkout -b feature/my-feature
   ```

2. Make your changes

3. Run the full check suite:
   ```bash
   cd tools/<tool>
   make check  # Runs lint + build + test
   ```

4. Commit with a descriptive message

5. Push and open a pull request

### Code Style

- Crystal code is formatted using `crystal tool format`
- Run `make format` to auto-format
- Run `make lint` to check formatting

### Testing

- Unit tests live in `spec/`
- Integration tests live in `spec/integration/`
- Run `make test` to run all tests
- Run `make check` to run lint + build + test

## Adding a New Tool

1. Create the tool directory:
   ```bash
   mkdir -p tools/newtool/{src,spec,bin}
   ```

2. Copy scaffolding from an existing tool (e.g., statusline)

3. Update the root Makefile to include the new tool

4. Add the tool to the root README.md

## Release Process

See individual tool `RELEASING.md` files for release instructions.

## Questions?

Open an issue for questions or discussion.
