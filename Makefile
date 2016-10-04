.PHONY: compile xref eunit clean edoc check make test

all: compile xref
test: eunit

# for busy typos
m: all
ma: all
mak: all
make: all

compile: 
	@./rebar3 compile

xref: compile
	@./rebar3 xref

test: eunit
eunit: compile
	@./rebar3 eunit

clean:
	@./rebar3 clean

doc:
	@./rebar3 edoc

check: compile
#	@echo "you need ./rebar3 build-plt before make check"
	@./rebar3 dialyzer

crosslang:
	@echo "do ERL_LIBS=../ before you make crosslang or fail"
	cd test && make crosslang
