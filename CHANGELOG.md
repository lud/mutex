# Changelog

All notable changes to this project will be documented in this file.

## [3.0.6] - 2026-07-04

### 📚 Documentation

- Enable ex_doc markdown formatter

## [3.0.5] - 2026-05-29

### ⚙️ Miscellaneous Tasks

- Fix compilation warnings for Elixir 1.20

## [3.0.4] - 2026-05-10

### ⚙️ Miscellaneous Tasks

- Maintenance release (deps, docs)

## [3.0.3] - 2026-02-03

### ⚙️ Miscellaneous Tasks

- Maintenance release

## [3.0.2] - 2025-10-16

### ⚙️ Miscellaneous Tasks

- Fixed Elixir 1.19 compilation warnings

## [3.0.1] - 2025-05-13

### 🐛 Bug Fixes

- Do not sleep  before notifying multiple waiters that a lock is available

### 🚜 Refactor

- Removed dead code

### ⚙️ Miscellaneous Tasks

- Update dependabot config (#8)
- Update CI config (#9)
- Fix dialyzer warning
- Update dependabot config (#15)
- Update Elixir Github workflow (#21)

## [3.0.0] - 2024-10-12

### 🚀 Features

- Added support for process name registration
- [**breaking**] Removed mutex metadata
- [**breaking**] Options in start_link must now always be a Keyword
- Removed need to cleanup state every N seconds
- Added the give_away function to transfer lock ownership
- Renamed 'under' functions to 'with_lock'
- [**breaking**] Releasing a lock is now a synchronous operation

### 🧪 Testing

- Splitted tests for speed

### ⚙️ Miscellaneous Tasks

- Fix github workflow for tests

## [2.0.0] - 2024-01-25

### ⚙️ Miscellaneous Tasks

- Upgrade to elixir version 1.15

## [1.0.2] - 2018-03-02

