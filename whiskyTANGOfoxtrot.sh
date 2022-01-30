#!/bin/bash

# Merge multiple repositories into one big monorepo. Migrates every branch in
# every subrepo to the eponymous branch in the monorepo, with all files
# (including in the history) rewritten to live under a subdirectory.
#
# To use a separate temporary directory while migrating, set the GIT_TMPDIR
# envvar.
#
# To access the individual functions instead of executing main, source this
# script from bash instead of executing it.



# But First, to make sure you don't lose anything along the way

stash() {
  # check if we have uncommited changes to stash
  git status --porcelain | grep "^." >/dev/null;

  if [ $? -eq 0 ]
  then
    if git stash save -u "git-update on tomono.sh `date`";
    then
      stash=1;
    fi
  fi
}

unstash() {
  # check if we have uncommited change to restore from the stash
  if [ $stash -eq 1 ]
  then
    git stash pop;
  fi
}

stash=0;

stash;

branch=`git branch | grep "\*" | cut -d " " -f 2-9`;

if [ "$branch" == "master" ]
then
  git pull origin master;
else

  git checkout master;
  git pull origin master;
  git checkout "$branch";
  git rebase master;

fi



${DEBUGSH:+set -x}
if [[ "$BASH_SOURCE" == "$0" ]]; then
	is_script=true
	set -eu -o pipefail
else
	is_script=false
fi

##### FUNCTIONS

# Silent pushd/popd
pushd () {
    command pushd "$@" > /dev/null
}

popd () {
    command popd "$@" > /dev/null
}

# Remove comments and empty lines from STDIN
function read_repositories {
	sed -e 's/#.*//' | grep .
}

# Simply list all files, recursively. No directories.
function ls-files-recursive {
	find . -type f | sed -e 's!..!!'
}

# List all branches for a given remote
function remote-branches {
	# With GNU find, this could have been:
	#
	#   find "$dir/.git/yada/yada" -type f -printf '%P\n'
	#
	# but it's not a real shell script if it's not compatible with a 14th
	# century OS from planet zorploid borploid.

	# Get into that git plumbing.  Cleanest way to list all branches without
	# text editing rigmarole (hard to find a safe escape character, as we've
	# noticed. People will put anything in branch names).
        if [ -n "$2" ]; then
		echo "$2" | tr ' ' '\n'
	else 
		pushd "$monorepo_dir/.git/refs/remotes/$1/"
		ls-files-recursive
		popd
	fi
}

# Create a monorepository in a directory "core". Read repositories from STDIN:
# one line per repository, with two space separated values:
#
# 1. The (git cloneable) location of the repository
# 2. The name of the target directory in the core repository
function create-mono {

	# This directory will contain all final tag refs (namespaced)
	mkdir -p .git/refs/namespaced-tags

	read_repositories | while IFS=';' read repo name folder branchs; do
		# Default name of the mono repository (override with envvar)
		: "${MONOREPO_NAME=$name}"

		# Monorepo directory
		monorepo_dir="$PWD/$MONOREPO_NAME"

				# Pretty risky, check double-check!
		if [[ "${1:-}" == "--continue" ]]; then
			if [[ ! -d "$MONOREPO_NAME" ]]; then
				echo "--continue specified, but nothing to resume" >&2
				exit 1
			fi
			pushd "$MONOREPO_NAME"
		else
			if [[ -d "$MONOREPO_NAME" ]]; then
				echo "Target repository directory $MONOREPO_NAME already exists." >&2
				return 1
			fi
			mkdir "$MONOREPO_NAME"
			pushd "$MONOREPO_NAME"
			git init
		fi

		if [[ -z "$name" ]]; then
			echo "pass REPOSITORY NAME pairs on stdin" >&2
			return 1
		elif [[ "$name" = */* ]]; then
			echo "Forward slash '/' not supported in repo names: $name" >&2
			return 1
		fi

                if [[ -z "$folder" ]]; then
			folder="$name"
                fi

		echo "Merging in $repo.." >&2
		git remote add "$name" "$repo"
		echo "Fetching $name.." >&2 
		git fetch "$name" >&2

		# Now we've got all tags in .git/refs/tags: put them away for a sec
		if [[ -n "$(ls .git/refs/tags)" ]]; then
			mkdir -p mv .git/refs/tags ".git/refs/namespaced-tags/$name"
		fi

		# Merge every branch from the sub repo into the mono repo, into a
		# branch of the same name (create one if it doesn't exist).
		remote-branches "$name" "$branchs" | while read branch; do
echo branch=$branch
			if git rev-parse -q --verify "$branch"; then
				# Branch already exists, just check it out (and clean up the working dir)
				git checkout -q "$branch"
				git checkout -q -- .
				git clean -f -d
			else
				# Create a fresh branch with an empty root commit"
				git checkout -q --orphan "$branch"
				# The ignore unmatch is necessary when this was a fresh repo
				git rm -rfq --ignore-unmatch .
				git commit -q --allow-empty -m "Root commit for $branch branch"
			fi
			git merge -q --no-commit -s ours "$name/$branch" --allow-unrelated-histories
			git read-tree --prefix="$folder/" "$name/$branch"
			git commit -q --no-verify --allow-empty -m "Merging $name to $branch"
		done
	done

	# Restore all namespaced tags
	rm -rf .git/refs/tags
	mv .git/refs/namespaced-tags .git/refs/tags

	# git checkout -t -b develop another_repo/develop # Start using remote repo immediately
	# git checkout -q develop
	# git checkout -q .
}

if [[ "$is_script" == "true" ]]; then
	create-mono "${1:-}"
fi

unstash;