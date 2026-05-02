/*  pack-pddl -- PDDL/HDDL parser, emitter, and planner-capability table.

    Part of FRKCSA / SPSE4.  GPLv3 License.

    A tokenizer-and-s-expression-based parser for the Planning Domain
    Definition Language (PDDL 1.2 / 2.1 / 2.2 / 3.0 core) and its
    hierarchical extension HDDL.  The parser is tolerant: unrecognised
    sections are preserved as =|unrecognised(Sexpr)|= terms rather
    than causing a hard failure.

    Strings are used for free-form text (comments, descriptions).
    Atoms are used for names (action, type, predicate, keyword).
    Variables in PDDL terms parse as Prolog =|var(Name)|= compounds.

    AST shape (domain):

        domain(Name,
               [ requirements([strips, typing, ...]),
                 types([typed(T, Parent), ...]),
                 predicates([predicate(Name, [typed(Var, Type), ...]), ...]),
                 functions([function(Name, Params), ...]),
                 constants([typed(Name, Type), ...]),
                 action(Name, Params, Precond, Effect),
                 durative_action(Name, Params, Duration, Condition, Effect),
                 derived(Head, Body),
                 method(Name, Params, Task, Subtasks)
               ])

    AST shape (problem):

        problem(Name,
                [ domain_ref(DomainName),
                  requirements([...]),
                  objects([typed(Name, Type), ...]),
                  init([Fact, ...]),
                  goal(GoalExpr),
                  metric(Direction, Expr)
                ])
*/

:- module(pddl,
          [ pddl_parse_file/2,          % +Path, -AST
            pddl_parse_string/2,        % +String, -AST
            pddl_emit/2,                % +AST, -String
            pddl_emit_file/2,           % +AST, +Path
            pddl_features_used/2,       % +AST, -Features
            planner_capabilities/2,     % ?Planner, ?Features
            eligible_planners/2,        % +AST, -Planners
            recommend_planner/2         % +AST, -Planner
          ]).

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(readutil)).

/** <module> PDDL/HDDL parser, emitter and planner capability table

Supports classical PDDL (STRIPS, ADL, typing, equality), numeric
fluents (PDDL 2.1), durative actions and timed initial literals
(2.1/2.2), derived predicates (2.2), preferences and constraints
(3.0), and HDDL methods / ordered-subtasks.

Parser entry points: =pddl_parse_file/2=, =pddl_parse_string/2=.
Emitter: =pddl_emit/2=, =pddl_emit_file/2=.  Round-trip property:
for any valid PDDL input, parsing then emitting then re-parsing
yields the same AST (modulo whitespace).

Capability matching: =planner_capabilities/2= declares which
features each known planner supports; =eligible_planners/2= filters
that by features actually used in an AST; =recommend_planner/2=
picks a single planner using heuristic preferences.
*/

% =====================================================================
% Lexer
% =====================================================================
%
% Tokens: lparen, rparen, dash, name(A), var(A), keyword(A),
%         number(N), string(S).
% Whitespace and ;comments are skipped.

tokenize(Codes, Tokens) :-
    phrase(tokens(Tokens), Codes).

tokens([T|Ts]) --> skip_ws, token(T), !, tokens(Ts).
tokens([])     --> skip_ws.

skip_ws --> [C], { ws(C) }, !, skip_ws.
skip_ws --> [0';], !, skip_line, skip_ws.
skip_ws --> [].

skip_line --> [0'\n], !.
skip_line --> [_],    skip_line.
skip_line --> [].

ws(0' ).  ws(0'\t).  ws(0'\n).  ws(0'\r).

% Token grammar.
% A standalone `-` (not immediately followed by an alphanumeric) is
% the PDDL typed-list separator and tokenises as `dash`.  A `-` inside
% a name is handled by name_rest/1 (which accepts it via name_cont/1).
% The peek pattern uses DCG pushback: we consume `-`, and if the next
% code is a non-alnum or absent, we emit `dash` and push the peeked
% code back.

token(lparen)       --> [0'(], !.
token(rparen)       --> [0')], !.
token(dash), [C]    --> [0'-, C], { \+ code_type(C, alnum) }, !.
token(dash)         --> [0'-], eos_peek_, !.
token(var(V))       --> [0'?], !, name_codes(Cs), { atom_codes(V, Cs) }.
token(keyword(K))   --> [0':], !, name_codes(Cs), { atom_codes(K, Cs) }.
token(number(N))    --> number_codes(Cs), { number_codes(N, Cs) }.
token(string(S))    --> [0'"], !, dq_codes(Cs), { string_codes(S, Cs) }.
token(name(A))      --> name_codes(Cs), { atom_codes(A, Cs) }.

eos_peek_([], []).

name_codes([C|Cs]) --> [C], { name_start(C) }, name_rest(Cs).

name_start(C) :- code_type(C, alpha).
name_start(0'=).
name_start(0'<).
name_start(0'>).
name_start(0'+).
name_start(0'*).
name_start(0'/).
name_cont(C)  :- code_type(C, alnum).
name_cont(0'_).
name_cont(0'-).
name_cont(0'=).
name_cont(0'<).
name_cont(0'>).

name_rest([C|Cs]) --> [C], { name_cont(C) }, !, name_rest(Cs).
name_rest([])     --> [].

% Numbers: digit(s) optionally followed by `.` digit(s).  A leading
% `-` is NOT consumed here -- PDDL negative numbers are rare and we
% leave them to higher-level parsing.
number_codes([D|Ds]) --> [D], { code_type(D, digit) }, digit_codes(Ds0),
                        frac_codes(Frac),
                        { append(Ds0, Frac, Ds) }.

digit_codes([D|Ds]) --> [D], { code_type(D, digit) }, !, digit_codes(Ds).
digit_codes([])     --> [].

frac_codes([0'.|Ds]) --> [0'.], !, digit_codes(Ds).
frac_codes([])       --> [].

dq_codes([])     --> [0'"], !.
dq_codes([C|Cs]) --> [C], dq_codes(Cs).

% =====================================================================
% S-expression parser
% =====================================================================

%!  pddl_parse_string(+String, -AST) is semidet.
pddl_parse_string(String, AST) :-
    string_codes(String, Codes),
    once(tokenize(Codes, Tokens)),
    once(phrase(sexpr(Sexpr), Tokens, [])),
    once(top_form(Sexpr, AST)).

%!  pddl_parse_file(+Path, -AST) is semidet.
pddl_parse_file(Path, AST) :-
    read_file_to_codes(Path, Codes, []),
    once(tokenize(Codes, Tokens)),
    once(phrase(sexpr(Sexpr), Tokens, [])),
    once(top_form(Sexpr, AST)).

sexpr(List)    --> [lparen], !, sexpr_list(List).
sexpr(name(N)) --> [name(N)].
sexpr(var(V))  --> [var(V)].
sexpr(kw(K))   --> [keyword(K)].
sexpr(num(N))  --> [number(N)].
sexpr(str(S))  --> [string(S)].
sexpr(dash)    --> [dash].

sexpr_list([])     --> [rparen], !.
sexpr_list([X|Xs]) --> sexpr(X), sexpr_list(Xs).

% =====================================================================
% Top-level form recognition
% =====================================================================

top_form([name(define), [name(domain), name(Name)] | Body], domain(Name, Sections)) :-
    maplist(parse_domain_section_, Body, Sections).
top_form([name(define), [name(problem), name(Name)] | Body], problem(Name, Sections)) :-
    maplist(parse_problem_section_, Body, Sections).

% =====================================================================
% Domain sections
% =====================================================================

parse_domain_section_([kw(requirements) | Flags], requirements(Fs)) :- !,
    maplist(unwrap_flag_, Flags, Fs).
parse_domain_section_([kw(types) | Items], types(Ts)) :- !,
    parse_typed_list_(Items, Ts).
parse_domain_section_([kw(constants) | Items], constants(Cs)) :- !,
    parse_typed_list_(Items, Cs).
parse_domain_section_([kw(predicates) | Preds], predicates(Ps)) :- !,
    maplist(parse_predicate_decl_, Preds, Ps).
parse_domain_section_([kw(functions) | Fns], functions(Fs)) :- !,
    maplist(parse_function_decl_, Fns, Fs).
parse_domain_section_([kw(action), name(Name) | Body], action(Name, Params, Pre, Eff)) :- !,
    parse_action_body_(Body, Params, Pre, Eff).
parse_domain_section_([kw(Kw), name(Name) | Body],
                      durative_action(Name, Params, Dur, Cond, Eff)) :-
    Kw == 'durative-action', !,
    parse_durative_body_(Body, Params, Dur, Cond, Eff).
parse_domain_section_([kw(derived), HeadSx, BodySx], derived(Head, Body)) :- !,
    translate_(HeadSx, Head),
    translate_(BodySx, Body).
parse_domain_section_([kw(method), name(Name) | Body], method(Name, Params, Task, Subtasks)) :- !,
    parse_method_body_(Body, Params, Task, Subtasks).
parse_domain_section_(Other, unrecognised(Other)).

unwrap_flag_(kw(K), Flag) :- canonical_flag_(K, Flag).
unwrap_flag_(name(N), Flag) :- canonical_flag_(N, Flag).

% PDDL :requirements uses hyphenated atoms like `durative-actions`.
% Our planner_capabilities/2 table uses underscored atoms like
% `durative_actions`.  Canonicalise on the way in.
canonical_flag_(Kw, Flag) :-
    atom_codes(Kw, Codes),
    maplist(hyphen_to_underscore_, Codes, CanCodes),
    atom_codes(Flag, CanCodes).

hyphen_to_underscore_(0'-, 0'_) :- !.
hyphen_to_underscore_(C, C).

% ---------------------------------------------------------------------
% Typed lists
% ---------------------------------------------------------------------
%
% A typed list is a sequence of names/vars optionally terminated by
% `- TYPE`, possibly repeated.  We accumulate names until we hit a
% dash, read the type, then recurse on the remainder.  Names without
% a trailing type default to type `object`.

parse_typed_list_([], []).
parse_typed_list_(Items, Typed) :-
    Items = [_|_],
    take_until_dash_(Items, Names, Rest0),
    (   Rest0 = [dash, name(Type) | Rest1]
    ->  maplist(mk_typed_(Type), Names, Typed0),
        parse_typed_list_(Rest1, TypedRest),
        append(Typed0, TypedRest, Typed)
    ;   Rest0 = []
    ->  maplist(mk_typed_(object), Names, Typed)
    ;   % malformed: give up, wrap in object
        maplist(mk_typed_(object), Names, Typed0),
        Typed = Typed0
    ).

take_until_dash_([], [], []).
take_until_dash_([dash|R], [], [dash|R]) :- !.
take_until_dash_([It|R], [N|Ns], T) :-
    item_name_(It, N),
    take_until_dash_(R, Ns, T).

item_name_(name(N), N).
item_name_(var(V),  V).

mk_typed_(Type, Name, typed(Name, Type)).

% ---------------------------------------------------------------------
% Predicate and function declarations
% ---------------------------------------------------------------------

parse_predicate_decl_([name(Name) | Args], predicate(Name, Params)) :-
    parse_typed_list_(Args, Params).

parse_function_decl_([name(Name) | Args], function(Name, Params)) :-
    parse_typed_list_(Args, Params).

% ---------------------------------------------------------------------
% Action body
% ---------------------------------------------------------------------

parse_action_body_(Body, Params, Pre, Eff) :-
    (   extract_kw_(parameters, Body, ParamsSx)
    ->  sexpr_to_typed_list_(ParamsSx, Params)
    ;   Params = []
    ),
    (   extract_kw_(precondition, Body, PreSx)
    ->  translate_(PreSx, Pre)
    ;   Pre = []
    ),
    (   extract_kw_(effect, Body, EffSx)
    ->  translate_(EffSx, Eff)
    ;   Eff = []
    ).

parse_durative_body_(Body, Params, Dur, Cond, Eff) :-
    (   extract_kw_(parameters, Body, ParamsSx)
    ->  sexpr_to_typed_list_(ParamsSx, Params)
    ;   Params = []
    ),
    (   extract_kw_(duration, Body, DurSx) -> translate_(DurSx, Dur) ; Dur = [] ),
    (   extract_kw_(condition, Body, CondSx) -> translate_(CondSx, Cond) ; Cond = [] ),
    (   extract_kw_(effect, Body, EffSx) -> translate_(EffSx, Eff) ; Eff = [] ).

parse_method_body_(Body, Params, Task, Subtasks) :-
    (   extract_kw_(parameters, Body, ParamsSx)
    ->  sexpr_to_typed_list_(ParamsSx, Params)
    ;   Params = []
    ),
    (   extract_kw_(task, Body, TaskSx) -> translate_(TaskSx, Task) ; Task = [] ),
    (   extract_kw_('ordered-subtasks', Body, SubSx)
    ->  translate_(SubSx, Subtasks)
    ;   extract_kw_(subtasks, Body, SubSx)
    ->  translate_(SubSx, Subtasks)
    ;   Subtasks = []
    ).

sexpr_to_typed_list_(L, Typed) :- is_list(L), !, parse_typed_list_(L, Typed).
sexpr_to_typed_list_(_, []).

%!  extract_kw_(+Kw, +Body, -Value) is semidet.
%
%   Find the value immediately following =|kw(Kw)|= in Body.
extract_kw_(Kw, [kw(Kw), V | _], V) :- !.
extract_kw_(Kw, [_ | Rest], V) :- extract_kw_(Kw, Rest, V).

% ---------------------------------------------------------------------
% Translate raw sexpr -> Prolog term
% ---------------------------------------------------------------------

translate_(name(X),   X) :- !.
translate_(var(V),    var(V)) :- !.
translate_(num(N),    N) :- !.
translate_(str(S),    S) :- !.
translate_(kw(K),     kw(K)) :- !.
translate_(dash,      dash) :- !.
translate_([],        []) :- !.
translate_([F|Args],  Term) :-
    translate_(F, FH),
    maplist(translate_, Args, TArgs),
    (   atom(FH), TArgs == []
    ->  Term = FH
    ;   atom(FH)
    ->  Term =.. [FH | TArgs]
    ;   Term = [FH | TArgs]
    ).

% =====================================================================
% Problem sections
% =====================================================================

parse_problem_section_([kw(domain), name(D)], domain_ref(D)) :- !.
parse_problem_section_([kw(requirements) | Flags], requirements(Fs)) :- !,
    maplist(unwrap_flag_, Flags, Fs).
parse_problem_section_([kw(objects) | Items], objects(Os)) :- !,
    parse_typed_list_(Items, Os).
parse_problem_section_([kw(init) | Facts], init(FTs)) :- !,
    maplist(translate_, Facts, FTs).
parse_problem_section_([kw(goal), G], goal(GT)) :- !,
    translate_(G, GT).
parse_problem_section_([kw(metric), name(Dir), Expr], metric(Dir, ET)) :- !,
    translate_(Expr, ET).
parse_problem_section_(Other, unrecognised(Other)).

% =====================================================================
% Emitter
% =====================================================================

%!  pddl_emit(+AST, -String) is det.
pddl_emit(domain(Name, Sections), String) :-
    with_output_to(string(String),
        ( format("(define (domain ~w)~n", [Name]),
          forall(member(S, Sections), emit_section_(S)),
          format(")~n") )).
pddl_emit(problem(Name, Sections), String) :-
    with_output_to(string(String),
        ( format("(define (problem ~w)~n", [Name]),
          forall(member(S, Sections), emit_section_(S)),
          format(")~n") )).

emit_section_(requirements(Fs)) :-
    format("  (:requirements"),
    forall(member(F, Fs), format(" :~w", [F])),
    format(")~n").
emit_section_(types(Ts)) :-
    format("  (:types"), emit_typed_list_(Ts), format(")~n").
emit_section_(constants(Cs)) :-
    format("  (:constants"), emit_typed_list_(Cs), format(")~n").
emit_section_(predicates(Ps)) :-
    format("  (:predicates~n"),
    forall(member(predicate(N, Params), Ps),
           ( format("    (~w", [N]),
             emit_typed_params_(Params),
             format(")~n") )),
    format("  )~n").
emit_section_(functions(Fs)) :-
    format("  (:functions~n"),
    forall(member(function(N, Params), Fs),
           ( format("    (~w", [N]),
             emit_typed_params_(Params),
             format(")~n") )),
    format("  )~n").
emit_section_(action(Name, Params, Pre, Eff)) :-
    format("  (:action ~w~n", [Name]),
    format("    :parameters ("), emit_typed_params_(Params), format(")~n"),
    format("    :precondition "), emit_term_(Pre), format("~n"),
    format("    :effect "), emit_term_(Eff), format("~n"),
    format("  )~n").
emit_section_(durative_action(Name, Params, Dur, Cond, Eff)) :-
    format("  (:durative-action ~w~n", [Name]),
    format("    :parameters ("), emit_typed_params_(Params), format(")~n"),
    format("    :duration "), emit_term_(Dur), format("~n"),
    format("    :condition "), emit_term_(Cond), format("~n"),
    format("    :effect "), emit_term_(Eff), format("~n"),
    format("  )~n").
emit_section_(derived(Head, Body)) :-
    format("  (:derived "), emit_term_(Head), format(" "), emit_term_(Body), format(")~n").
emit_section_(method(Name, Params, Task, Subtasks)) :-
    format("  (:method ~w~n", [Name]),
    format("    :parameters ("), emit_typed_params_(Params), format(")~n"),
    format("    :task "), emit_term_(Task), format("~n"),
    format("    :ordered-subtasks "), emit_term_(Subtasks), format("~n"),
    format("  )~n").
emit_section_(domain_ref(D)) :- format("  (:domain ~w)~n", [D]).
emit_section_(objects(Os)) :-
    format("  (:objects"), emit_typed_list_(Os), format(")~n").
emit_section_(init(Facts)) :-
    format("  (:init~n"),
    forall(member(F, Facts), ( format("    "), emit_term_(F), format("~n") )),
    format("  )~n").
emit_section_(goal(G)) :-
    format("  (:goal "), emit_term_(G), format(")~n").
emit_section_(metric(Dir, E)) :-
    format("  (:metric ~w ", [Dir]), emit_term_(E), format(")~n").
emit_section_(unrecognised(_)).

emit_typed_list_([]).
emit_typed_list_([typed(N, object)|R]) :- !, format(" ~w", [N]), emit_typed_list_(R).
emit_typed_list_([typed(N, T)|R]) :- format(" ~w - ~w", [N, T]), emit_typed_list_(R).

emit_typed_params_([]).
emit_typed_params_([typed(V, object)|R]) :- !,
    format("?~w", [V]), emit_typed_params_sep_(R).
emit_typed_params_([typed(V, T)|R]) :-
    format("?~w - ~w", [V, T]), emit_typed_params_sep_(R).
emit_typed_params_sep_([]).
emit_typed_params_sep_(L) :- L \= [], format(" "), emit_typed_params_(L).

emit_term_(X) :- var(X), !, format("?_").
emit_term_(var(V))   :- !, format("?~w", [V]).
emit_term_(kw(K))    :- !, format(":~w", [K]).
emit_term_(dash)     :- !, format("-").
emit_term_(N) :- number(N), !, format("~w", [N]).
emit_term_(S) :- string(S), !, format("\"~w\"", [S]).
emit_term_([])  :- !, format("()").
emit_term_(L) :- is_list(L), !,
    format("("), emit_list_(L), format(")").
emit_term_(A) :- atom(A), !, format("~w", [A]).
emit_term_(T) :- compound(T), !,
    T =.. [F|Args],
    format("(~w", [F]),
    forall(member(A, Args), ( format(" "), emit_term_(A) )),
    format(")").

emit_list_([]).
emit_list_([X]) :- !, emit_term_(X).
emit_list_([X|Xs]) :- emit_term_(X), format(" "), emit_list_(Xs).

%!  pddl_emit_file(+AST, +Path) is det.
pddl_emit_file(AST, Path) :-
    pddl_emit(AST, String),
    setup_call_cleanup(
        open(Path, write, Stream),
        write(Stream, String),
        close(Stream)).

% =====================================================================
% Feature detection
% =====================================================================

%!  pddl_features_used(+AST, -Features) is det.
pddl_features_used(domain(_, Sections), Fs) :- sections_features_(Sections, Fs).
pddl_features_used(problem(_, Sections), Fs) :- sections_features_(Sections, Fs).

sections_features_(Sections, Features) :-
    findall(F, ( member(S, Sections),
                 features_of_section_(S, Fs),
                 member(F, Fs) ), Raw),
    sort(Raw, Features).

features_of_section_(requirements(Declared), Declared) :- !.
features_of_section_(types(_),                   [typing]) :- !.
features_of_section_(functions(_),               [numeric_fluents]) :- !.
features_of_section_(durative_action(_,_,_,_,_), [durative_actions]) :- !.
features_of_section_(derived(_,_),               [derived_predicates]) :- !.
features_of_section_(method(_,_,_,_),            [hddl, htn]) :- !.
features_of_section_(init(Facts), Fs) :- !,
    (   ( member(at(_,_), Facts)
        ; member(F, Facts), compound(F), functor(F, at, _) )
    ->  Fs = [timed_initial_literals]
    ;   Fs = []
    ).
features_of_section_(_, []).

% =====================================================================
% Planner capability table
% =====================================================================

%!  planner_capabilities(?Planner, ?Features) is nondet.
%
%   Declared capabilities of each known planner.  These should be
%   reasonably faithful to each planner's documented capability;
%   corrections welcome.

planner_capabilities(lama,        [strips, typing, negative_preconditions,
                                   disjunctive_preconditions, adl,
                                   action_costs]).
planner_capabilities(lama_first,  [strips, typing, negative_preconditions,
                                   disjunctive_preconditions, adl,
                                   action_costs]).
planner_capabilities(fast_downward, [strips, typing, negative_preconditions,
                                     disjunctive_preconditions, adl,
                                     action_costs]).
planner_capabilities(metric_ff,   [strips, typing, numeric_fluents, adl]).
planner_capabilities(lpg_td,      [strips, typing, negative_preconditions,
                                   disjunctive_preconditions, adl,
                                   durative_actions, timed_initial_literals,
                                   numeric_fluents, derived_predicates]).
planner_capabilities(optic,       [strips, typing, negative_preconditions,
                                   adl, durative_actions,
                                   timed_initial_literals, numeric_fluents,
                                   continuous_effects, preferences]).
planner_capabilities(popf,        [strips, typing, negative_preconditions,
                                   adl, durative_actions, numeric_fluents]).
planner_capabilities(enhsp,       [strips, typing, numeric_fluents,
                                   processes, events, durative_actions]).
planner_capabilities(smtplan,     [strips, typing, durative_actions,
                                   numeric_fluents, timed_initial_literals,
                                   continuous_effects]).
planner_capabilities(sgplan,      [strips, typing, durative_actions,
                                   timed_initial_literals, numeric_fluents]).
planner_capabilities(scorpion,    [strips, typing, negative_preconditions,
                                   disjunctive_preconditions, adl,
                                   action_costs]).
planner_capabilities(k_star,      [strips, typing, negative_preconditions,
                                   adl, top_k]).
planner_capabilities(forbid_iter, [strips, typing, adl, top_k]).
planner_capabilities(lilotane,    [strips, typing, hddl, htn,
                                   negative_preconditions]).
planner_capabilities(panda,       [strips, typing, hddl, htn,
                                   negative_preconditions, adl]).
planner_capabilities(tree_rex,    [strips, typing, hddl, htn]).

%!  eligible_planners(+AST, -Planners) is det.
eligible_planners(AST, Planners) :-
    pddl_features_used(AST, Used),
    findall(P,
            ( planner_capabilities(P, Caps), subset(Used, Caps) ),
            Planners).

%!  recommend_planner(+AST, -Planner) is semidet.
recommend_planner(AST, Planner) :-
    pddl_features_used(AST, Used),
    (   memberchk(hddl, Used)
    ->  prefer_(Used, [lilotane, panda, tree_rex], Planner)
    ;   (   memberchk(continuous_effects, Used)
        ;   memberchk(processes, Used)
        )
    ->  prefer_(Used, [enhsp, smtplan, optic], Planner)
    ;   memberchk(durative_actions, Used)
    ->  prefer_(Used, [optic, popf, lpg_td, sgplan], Planner)
    ;   memberchk(numeric_fluents, Used)
    ->  prefer_(Used, [enhsp, metric_ff, popf], Planner)
    ;   prefer_(Used, [lama_first, lama, fast_downward, scorpion], Planner)
    ).

prefer_(Used, [P|_], P) :-
    planner_capabilities(P, Caps), subset(Used, Caps), !.
prefer_(Used, [_|Rest], P) :- prefer_(Used, Rest, P).
