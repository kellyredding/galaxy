# RSpec Style Guide

## Naming
- Use `let(:unit_class)` instead of `described_class`
- Use dot notation for method descriptions (`.method_name`, `#instance_method`)

## Organization
- Collapse related expectations into single specs when testing the same scenario
- Use `let!` for database records; use `let` for simple values that don't need eager evaluation

## Factories
- Prefer `build_stubbed` over `create` when you don't need persistence
- Use traits for common variations
