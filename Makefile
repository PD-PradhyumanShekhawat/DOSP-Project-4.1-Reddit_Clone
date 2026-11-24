
ERLC = erlc
ERL = erl

SRC_DIR = src
TEST_DIR = test
EBIN_DIR = ebin

SRC_FILES = $(wildcard $(SRC_DIR)/*.erl)
TEST_FILES = $(wildcard $(TEST_DIR)/*.erl)

.PHONY: all compile test clean simulate simulate-lifecycle benchmark

all: compile

compile:
	mkdir -p $(EBIN_DIR)
	$(ERLC) -Wall -o $(EBIN_DIR) $(SRC_FILES)

test: compile
	$(ERLC) -Wall -o $(EBIN_DIR) $(TEST_FILES)
	$(ERL) -noshell -pa $(EBIN_DIR) -eval 'case eunit:test(reddit_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.'

simulate: compile
	$(ERL) -noshell -pa $(EBIN_DIR) -eval 'reddit_simulator:run(100), halt().'

simulate-lifecycle: compile
	$(ERL) -noshell -pa $(EBIN_DIR) -eval 'reddit_simulator:run_lifecycle(100, #{}), halt().'

benchmark: compile
	mkdir -p results
	$(ERLC) -Wall -o $(EBIN_DIR) scripts/performance_test.erl
	$(ERL) -noshell -pa $(EBIN_DIR) -eval 'case performance_test:run() of {ok, _} -> halt(0); Error -> io:format("Benchmark error: ~p~n", [Error]), halt(1) end.'
	
clean:
	rm -rf $(EBIN_DIR) erl_crash.dump
