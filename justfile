install:
  mix deps.get

format:
  mix format

_git_status:
    git status

test-cover:
  mix test --cover

dialyzer:
  mix dialyzer

credo:
  mix credo

check: install format test-cover credo dialyzer _git_status
