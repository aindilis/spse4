/*  run_all_tests.pl  --  SPSE4 test suite runner.

    Loads all six packs and runs their PlUnit test files.

    Usage:  swipl -s run_all_tests.pl

    The script is defensive: it reports every path it tries to use
    and every .plt file it tries to load, so diagnosing a missing
    file or misnamed directory is straightforward.
*/

:- use_module(library(plunit)).
:- use_module(library(lists)).

:- prolog_load_context(directory, Here),
   nb_setval(spse4_root, Here).

add_pack_(Pack) :-
    nb_getval(spse4_root, Root),
    atomic_list_concat([Root, '/', Pack, '/prolog'], Dir),
    (   exists_directory(Dir)
    ->  asserta(user:file_search_path(library, Dir)),
        format("  added search path: ~w~n", [Dir])
    ;   format("  MISSING pack dir: ~w~n", [Dir])
    ).

try_load_module_(Mod) :-
    catch(use_module(library(Mod)),
          E,
          (   format("  FAILED to load library(~w): ~q~n", [Mod, E]),
              fail
          )),
    format("  loaded library(~w)~n", [Mod]),
    !.
try_load_module_(_).

try_load_testfile_(Pack, Rel) :-
    nb_getval(spse4_root, Root),
    atomic_list_concat([Root, '/', Pack, '/t/', Rel], Path),
    (   exists_file(Path)
    ->  consult(Path),
        format("  loaded test file: ~w~n", [Path])
    ;   format("  MISSING test file: ~w~n", [Path])
    ).

setup_ :-
    format("~n---- Registering pack search paths ----~n"),
    add_pack_('pack-allen'),
    add_pack_('pack-mt-store'),
    add_pack_('pack-spse4-core'),
    add_pack_('pack-pddl'),
    add_pack_('pack-spse4-scheduler'),
    add_pack_('pack-spse4-server'),

    format("~n---- Loading pack modules ----~n"),
    try_load_module_(allen),
    try_load_module_(mt_store),
    try_load_module_(spse4_core),
    try_load_module_(pddl),
    try_load_module_(spse4_scheduler),
    try_load_module_(spse4_server),

    format("~n---- Loading test files ----~n"),
    try_load_testfile_('pack-allen',            'allen.plt'),
    try_load_testfile_('pack-mt-store',         'mt_store.plt'),
    try_load_testfile_('pack-mt-store',         'mt_store_mysql.plt'),
    try_load_testfile_('pack-spse4-core',       'spse4_core.plt'),
    try_load_testfile_('pack-pddl',             'pddl.plt'),
    try_load_testfile_('pack-spse4-scheduler',  'spse4_scheduler.plt'),
    try_load_testfile_('pack-spse4-server',     'spse4_server.plt').

:- initialization(main, main).

main :-
    setup_,
    format("~n==== Running SPSE4 test suite ====~n"),
    (   run_tests
    ->  format("==== All tests passed ====~n"),
        halt(0)
    ;   format("==== TESTS FAILED ====~n"),
        halt(1)
    ).
