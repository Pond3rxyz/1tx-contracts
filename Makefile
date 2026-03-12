# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

# Dependencies
update :; forge update

# Build
build      :; forge build --sizes
build-deploy :; FOUNDRY_PROFILE=deploy forge build --sizes

# Test
test      :; forge test -vvv
test-unit :; forge test -vvv --no-match-path "test/fork/*"
test-fork :; forge test -vvv --match-path "test/fork/*"
test-fuzz :; forge test -vvv --match-path "test/fuzz/*"
test-pr   :; FOUNDRY_PROFILE=pr forge test -vvv
test-ci   :; FOUNDRY_PROFILE=ci forge test -vvv

# Formatting & linting
fmt       :; forge fmt
fmt-check :; forge fmt --check
lint      :; npx solhint 'src/**/*.sol'
lint-fix  :; npx solhint 'src/**/*.sol' --fix
check     :; forge fmt --check && npx solhint 'src/**/*.sol'

# Coverage
coverage-base :; FOUNDRY_PROFILE=coverage forge coverage --report lcov --no-match-coverage "(script/.*)"
coverage-clean :; lcov --rc derive_function_end_line=0 --remove ./lcov.info -o ./lcov.info.p --ignore-errors inconsistent
coverage-report :; genhtml ./lcov.info.p -o report --branch-coverage --rc derive_function_end_line=0
coverage :
	make coverage-base
	make coverage-clean
	make coverage-report

# Utilities
snapshot :; forge snapshot
gas-report :; forge test --gas-report
clean :; forge clean && rm -rf report lcov.info lcov.info.p

.PHONY: update build build-deploy test test-unit test-fork test-fuzz test-pr test-ci fmt fmt-check lint lint-fix check coverage-base coverage-clean coverage-report coverage snapshot gas-report clean
