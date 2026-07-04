_mix_deps:
  mix deps.get

format:
  mix format --migrate

_git_status:
    git status

test-cover:
  mix test --cover

dialyzer:
  mix dialyzer

credo:
  mix credo

readme:
  mix rdmx.update README.md

_libdev_check:
  mix libdev.check

check: _mix_deps format readme _libdev_check _git_status
