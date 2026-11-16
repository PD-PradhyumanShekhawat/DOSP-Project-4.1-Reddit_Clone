
ERLC = erlc
ERL = erl

SRC_DIR = src
TEST_DIR = test
EBIN_DIR = ebin

SRC_FILES = $(wildcard $(SRC_DIR)/*.erl)
TEST_FILES = $(wildcard $(TEST_DIR)/*.erl)

.PHONY: all compile test clean simulate

all: compile

compile:
	mkdir -p $(EBIN_DIR)
	$(ERLC) -Wall -o $(EBIN_DIR) $(SRC_FILES)

test: compile
	$(ERLC) -Wall -o $(EBIN_DIR) $(TEST_FILES)
	$(ERL) -noshell -pa $(EBIN_DIR) -eval 'case eunit:test(reddit_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.'

simulate: compile
	$(ERL) -noshell -pa $(EBIN_DIR) -eval 'reddit_simulator:run_workload(100), halt().'

simulate-large: compile
	$(ERL) -noshell -pa $(EBIN_DIR) -eval 'reddit_simulator:run_workload(1000), halt().'

clean:
	rm -rf $(EBIN_DIR) erl_crash.dump
