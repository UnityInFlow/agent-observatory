-- Agent Observatory baseline schema.
--
-- This is the *experiment truth* store (chapter 00 §27). It deliberately does NOT
-- mirror any vendor's span names and is NOT a telemetry warehouse: raw spans live in
-- Tempo, aggregates live in Prometheus, and only normalized experiment data lands here.

create table experiment (
    id          uuid         primary key,
    name        varchar(200) not null,
    hypothesis  text,
    created_at  timestamp with time zone not null
);

create table benchmark (
    id                  varchar(64)  primary key,
    name                varchar(200) not null,
    category            varchar(64)  not null,
    repository          varchar(200),
    prompt              text,
    constraints         text,
    acceptance_criteria text,
    evaluator_version   varchar(32),
    baseline_commit     varchar(64)
);

-- Section 12: recording only `variant = instructions` is not reproducible. The exact
-- customization files used for a run are hashed and referenced from the run.
create table customization_snapshot (
    id                 uuid primary key,
    instructions_hash  varchar(64),
    skills_hash        varchar(64),
    agent_hash         varchar(64),
    hooks_hash         varchar(64),
    mcp_hash           varchar(64)
);

create table agent_run (
    id                  uuid        primary key,
    experiment_id       uuid        references experiment (id),
    benchmark_id        varchar(64) not null references benchmark (id),
    variant             varchar(64) not null,
    started_at          timestamp with time zone not null,
    finished_at         timestamp with time zone,

    provider            varchar(64) not null,
    product             varchar(64) not null,
    runtime_version     varchar(64),
    model               varchar(128),

    commit_sha          varchar(64),
    dirty_before_run    boolean     not null default false,
    customization_id    uuid        references customization_snapshot (id),

    model_calls         integer     not null default 0,
    tool_calls          integer     not null default 0,
    tool_failures       integer     not null default 0,
    retries             integer     not null default 0,
    permission_requests integer     not null default 0,
    permission_denials  integer     not null default 0,

    duration_ms         bigint,
    input_tokens        bigint,
    output_tokens       bigint,
    cached_tokens       bigint,
    estimated_cost      numeric(12, 6),

    added_lines         integer     not null default 0,
    deleted_lines       integer     not null default 0,
    changed_files       text,

    -- Section 17: correlation back to the raw trace, without duplicating it here.
    trace_id            varchar(64),
    telemetry_query_key varchar(200)
);

create index idx_agent_run_benchmark on agent_run (benchmark_id);
create index idx_agent_run_experiment on agent_run (experiment_id);
create index idx_agent_run_started_at on agent_run (started_at desc);

create table evaluation (
    id                        uuid        primary key,
    run_id                    uuid        not null unique references agent_run (id) on delete cascade,
    evaluator_version         varchar(32) not null,
    completed_at              timestamp with time zone not null,
    exit_code                 integer     not null,
    passed                    boolean     not null,
    failure_class             varchar(8),

    build_passed              boolean     not null,
    tests_passed              boolean     not null,
    acceptance_criteria_passed integer    not null,
    acceptance_criteria_total  integer    not null,

    unrelated_files_changed   integer     not null default 0,
    new_dependencies          integer     not null default 0,
    static_analysis_passed    boolean     not null default true,

    forbidden_action_attempts integer     not null default 0,
    secret_exposure_detected  boolean     not null default false
);

create table human_review (
    id               uuid         primary key,
    run_id           uuid         not null references agent_run (id) on delete cascade,
    reviewer         varchar(120) not null,
    reviewed_at      timestamp with time zone not null,
    correctness      integer,
    scope_discipline integer,
    maintainability  integer,
    test_quality     integer,
    notes            text
);

create index idx_human_review_run on human_review (run_id);
