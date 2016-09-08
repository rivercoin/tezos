
TESTS := store context state basic basic.sh

all: test

INCLUDES = $(patsubst %, -I %, $(SOURCE_DIRECTORIES))
OCAMLFLAGS = \
  -g -safe-string -w -40 \
  ${INCLUDES} \
  $(patsubst %, -package %, $(PACKAGES)) \
  ${EXTRA_OCAMLFLAGS}

SOURCE_DIRECTORIES := $(addprefix ../src/, \
  utils \
  compiler \
  node/db \
  node/net \
  node/updater \
  node/shell \
  proto \
)

PACKAGES := \
  base64 \
  calendar \
  cohttp.lwt \
  compiler-libs.optcomp \
  config-file \
  cryptokit \
  cstruct \
  dynlink \
  ezjsonm \
  git \
  irmin.unix \
  lwt \
  lwt.unix \
  ocplib-endian \
  ocplib-ocamlres \
  ocplib-json-typed \
  ocplib-resto.directory \
  sodium \
  unix

############################################################################
## External packages

NODELIB := ../src/utils.cmxa ../src/compiler.cmxa ../src/node.cmxa
CLIENTLIB := ../src/client.cmxa \
  $(patsubst ../src/client/embedded/%/, \
	     ../src/proto/client_embedded_proto_%.cmxa, \
             $(shell ls -d ../src/client/embedded/*/)) \
  $(patsubst ../src/client/embedded/%/, \
             ../src/client/embedded/client_%.cmx, \
	     $(shell ls -d ../src/client/embedded/*/))

${NODELIB} ${CLIENTLIB}:
	${MAKE} -C ../src $@

.PHONY: build-test run-test test
build-test: ${addprefix build-test-,${TESTS}}
run-test:
	@$(patsubst %,${MAKE} run-test-% &&, ${TESTS}) \
	  echo && echo "Success" && echo
test:
	@${MAKE} --no-print-directory build-test
	@${MAKE} --no-print-directory run-test

############################################################################
## Store test program

.PHONY:build-test-store run-test-store
build-test-store: test-store
run-test-store:
	./test-store

TEST_STORE_INTFS =

TEST_STORE_IMPLS = \
  test.ml \
  test_store.ml \

${TEST_STORE_IMPLS:.ml=.cmx}: ${NODELIB}
test-store: ${NODELIB} ${TEST_STORE_IMPLS:.ml=.cmx}
	ocamlfind ocamlopt -linkall -linkpkg ${OCAMLFLAGS} -o $@ $^

clean::
	rm -f test-store


############################################################################
## Context test program

.PHONY:build-test-context run-test-context
build-test-context: test-context
run-test-context:
	./test-context

TEST_CONTEXT_INTFS =

TEST_CONTEXT_IMPLS = \
  test.ml \
  test_context.ml \

${TEST_CONTEXT_IMPLS:.ml=.cmx}: ${NODELIB}
test-context: ${NODELIB} ${TEST_CONTEXT_IMPLS:.ml=.cmx}
	ocamlfind ocamlopt -linkall -linkpkg ${OCAMLFLAGS} -o $@ $^

clean::
	rm -f test-context


############################################################################
## State test program

.PHONY:build-test-state run-test-state
build-test-state: test-state
run-test-state:
	./test-state

TEST_STATE_INTFS =

TEST_STATE_IMPLS = \
  test.ml \
  test_state.ml \

${TEST_STATE_IMPLS:.ml=.cmx}: ${NODELIB}
test-state: ${NODELIB} ../src/proto/embedded_proto_demo.cmxa ${TEST_STATE_IMPLS:.ml=.cmx}
	ocamlfind ocamlopt -linkall -linkpkg ${OCAMLFLAGS} -o $@ $^

clean::
	rm -f test-state


############################################################################
## Basic-client-functionality test program

.PHONY:build-test-basic.sh run-test-basic.sh
build-test-basic.sh:
run-test-basic.sh:
	./test-basic.sh

.PHONY:build-test-basic run-test-basic
build-test-basic: test-basic
run-test-basic:
	./test-basic

TEST_BASIC_INTFS =

TEST_BASIC_IMPLS = \
  test.ml \
  test_basic.ml \

test-basic \
${TEST_BASIC_IMPLS:.ml=.cmx}: \
  SOURCE_DIRECTORIES+=../src/client ../src/client/embedded/

${TEST_BASIC_IMPLS:.ml=.cmx}: ${NODELIB} ${CLIENTLIB}
test-basic: ${NODELIB} ${CLIENTLIB} ${TEST_BASIC_IMPLS:.ml=.cmx}
	ocamlfind ocamlopt -linkall -linkpkg ${OCAMLFLAGS} -o $@ $^

clean::
	rm -f test-basic


############################################################################
## Generic rules

test.cmx: test.cmi

%.cmx: %.ml
	ocamlfind ocamlopt ${OCAMLFLAGS} -c $<

%.cmo: %.ml
	ocamlfind ocamlc ${OCAMLFLAGS} -c $<

%.cmi: %.mli
	ocamlfind ocamlc ${OCAMLFLAGS} -c $<

clean::
	-rm -f *.cm*

-include .depend
.depend: $(wildcard *.ml *.mli)
	ocamldep $^ > .depend

clean::
	-rm .depend