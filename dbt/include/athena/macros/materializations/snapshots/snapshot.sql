{%
  Hash function to generate dbt_scd_id. dbt by default uses md5(coalesce(cast(field as varchar)))
   but it does not work with athena. It throws an error Unexpected parameters (varchar) for function
   md5. Expected: md5(varbinary)
%}

{% macro athena__snapshot_hash_arguments(args) -%}
    to_hex(md5(to_utf8({%- for arg in args -%}
        coalesce(cast({{ arg }} as varchar ), '')
        {% if not loop.last %} || '|' || {% endif %}
    {%- endfor -%})))
{%- endmacro %}

{%
  Recreate the snapshot table from the new_snapshot_table
%}

{% macro athena__snapshot_merge_sql(target, source) -%}
    {%- set target_relation = adapter.get_relation(database=target.database, schema=target.schema, identifier=target.identifier) -%}
    {%- if target_relation is not none -%}
      {% do adapter.drop_relation(target_relation) %}
    {%- endif -%}

    {% set sql -%}
      SELECT * FROM {{ source }};
    {%- endset -%}

    {{ create_table_as(False, target_relation, sql) }}
{% endmacro %}

{%
  Create the snapshot table from the source with dbt snapshot columns
%}

{% macro build_snapshot_table(strategy, source_sql) %}
    SELECT *
      , {{ strategy.unique_key }} AS dbt_unique_key
      , {{ strategy.updated_at }} AS dbt_valid_from
      , {{ strategy.scd_id }} AS dbt_scd_id
      , 'insert' AS dbt_change_type
      , {{ end_of_time() }} AS dbt_valid_to
      , True AS is_current_record
      , {{ strategy.updated_at }} AS dbt_snapshot_at
    FROM ({{ source_sql }}) source;
{% endmacro %}

{%
  Identify records that needs to be upserted or deleted into the snapshot table
%}

{% macro snapshot_staging_table(strategy, source_sql, target_relation) -%}
    WITH snapshot_query AS (
        {{ source_sql }}
    )
    , snapshotted_data_base AS (
        SELECT *
          , ROW_NUMBER() OVER (
              PARTITION BY dbt_unique_key
              ORDER BY dbt_valid_from DESC
            ) AS dbt_snapshot_rn
        FROM {{ target_relation }}
    )
    , snapshotted_data AS (
        SELECT *
        FROM snapshotted_data_base
        WHERE dbt_snapshot_rn = 1
          AND dbt_change_type != 'delete'
    )
    , source_data AS (
        SELECT *
          , {{ strategy.unique_key }} AS dbt_unique_key
          , {{ strategy.updated_at }} AS dbt_valid_from
          , {{ strategy.scd_id }} AS dbt_scd_id
        FROM snapshot_query
    )
    , upserts AS (
        SELECT source_data.*
          , CASE
              WHEN snapshotted_data.dbt_unique_key IS NULL THEN 'insert'
              ELSE 'update'
            END as dbt_change_type
          , {{ end_of_time() }} AS dbt_valid_to
          , True AS is_current_record
        FROM source_data
        LEFT JOIN snapshotted_data
               ON snapshotted_data.dbt_unique_key = source_data.dbt_unique_key
        WHERE snapshotted_data.dbt_unique_key IS NULL
           OR (
                snapshotted_data.dbt_unique_key IS NOT NULL
            AND (
                {{ strategy.row_changed }}
            )
        )
    )
    {%- if strategy.invalidate_hard_deletes -%}
      , deletes AS (
          SELECT
              source_data.*
            , 'delete' AS dbt_change_type
            , {{ end_of_time() }} AS dbt_valid_to
            , True AS is_current_record
          FROM snapshotted_data
          LEFT JOIN source_data
                 ON snapshotted_data.dbt_unique_key = source_data.dbt_unique_key
          WHERE source_data.dbt_unique_key IS NULL
        )
      SELECT * FROM upserts
      UNION ALL
      SELECT * FROM deletes;
    {% else %}
    SELECT * FROM upserts;
    {% endif %}

{%- endmacro %}

{%
  Create a new temporary table to hold the records to be upserted or deleted
%}

{% macro athena__build_snapshot_staging_table(strategy, sql, target_relation) %}
    {%- set tmp_identifier = target_relation.identifier ~ '__dbt_tmp' -%}

    {%- set tmp_relation = api.Relation.create(identifier=tmp_identifier,
                                                  schema=target_relation.schema,
                                                  database=target_relation.database,
                                                  type='table') -%}

    {% do adapter.drop_relation(tmp_relation) %}

    {%- set select = snapshot_staging_table(strategy, sql, target_relation) -%}

    {% call statement('build_snapshot_staging_relation') %}
        {{ create_table_as(False, tmp_relation, select) }}
    {% endcall %}

    {% do return(tmp_relation) %}
{% endmacro %}

{#
    Add new columns to the table if applicable
#}

{% macro athena__create_columns(relation, columns) -%}
  {% set query -%}
  ALTER TABLE {{ relation }} ADD COLUMNS (
  {%- for column in columns -%}
    {% if column.data_type|lower == 'boolean' %}
       {{ column.name }} BOOLEAN {%- if not loop.last -%},{%- endif -%}
    {% elif column.data_type|lower == 'character varying(256)' %}
      {{ column.name }} VARCHAR(255) {%- if not loop.last -%},{%- endif -%}
    {% elif column.data_type|lower == 'integer' %}
      {{ column.name }} BIGINT {%- if not loop.last -%},{%- endif -%}
    {% elif column.data_type|lower == 'float' %}
      {{ column.name }} FLOAT {%- if not loop.last -%},{%- endif -%}
    {% else %}
      {{ column.name }} {{ column.data_type }} {%- if not loop.last -%},{%- endif -%}
    {% endif %}
  {%- endfor %}
  )
  {%- endset -%}
  {% do run_query(query) %}
{% endmacro %}

{#
    Update the dbt_valid_to and is_current_record for
    snapshot rows being updated and create a new temporary table to hold them
#}

{% macro athena__create_new_snapshot_table(strategy, strategy_name, target, source) %}
    {%- set tmp_identifier = target.identifier ~ '__dbt_tmp_1' -%}

    {%- set tmp_relation = adapter.get_relation(database=target.database, schema=target.schema, identifier=tmp_identifier) -%}

    {%- set target_relation = api.Relation.create(identifier=tmp_identifier,
      schema=target.schema,
      database=target.database,
      type='table') -%}

    {%- set source_columns = adapter.get_columns_in_relation(source) -%}

    {% if tmp_relation is not none %}
      {% do adapter.drop_relation(tmp_relation) %}
    {% endif %}

    {% set sql -%}
      SELECT
        {% for column in source_columns %}
          {{ column.name }} {%- if not loop.last -%},{%- endif -%}
        {% endfor %}
        ,dbt_snapshot_at
      from {{ target }}
      WHERE dbt_unique_key NOT IN ( SELECT dbt_unique_key FROM {{ source }} )
      UNION ALL
      SELECT
        {% for column in source_columns %}
          {% if column.name == 'dbt_valid_to' %}
          CASE
          WHEN tgt.is_current_record
          THEN
          {% if strategy_name == 'timestamp' %}
            src.{{ strategy.updated_at }}
          {% else %}
            {{ strategy.updated_at }}
          {% endif %}
          ELSE tgt.dbt_valid_to
          END AS dbt_valid_to {%- if not loop.last -%},{%- endif -%}
          {% elif column.name == 'is_current_record' %}
          False AS is_current_record {%- if not loop.last -%},{%- endif -%}
          {% else %}
            tgt.{{ column.name }} {%- if not loop.last -%},{%- endif -%}
          {% endif %}
        {% endfor %}
        ,
        {% if strategy_name == 'timestamp' %}
            tgt.{{ strategy.updated_at }}
        {% else %}
          {{ strategy.updated_at }}
        {% endif %} AS dbt_snapshot_at
      FROM {{ target }} tgt
      JOIN {{ source }} src
      ON tgt.dbt_unique_key = src.dbt_unique_key
      UNION ALL
      SELECT
        {% for column in source_columns %}
            {{ column.name }} {%- if not loop.last -%},{%- endif -%}
        {% endfor %}
        ,{{ strategy.updated_at }} AS dbt_snapshot_at
      FROM {{ source }};
    {%- endset -%}

    {% call statement('create_new_snapshot_table') %}
        {{ create_table_as(False, target_relation, sql) }}
    {% endcall %}

    {% do return(target_relation) %}
{% endmacro %}

{% materialization snapshot, adapter='athena' %}
  {%- set config = model['config'] -%}

  {%- set target_table = model.get('alias', model.get('name')) -%}

  {%- set strategy_name = config.get('strategy') -%}
  {%- set unique_key = config.get('unique_key') %}
  {%- set file_format = config.get('file_format', 'parquet') -%}

  {{ log('Checking if target table exists') }}
  {% set target_relation_exists, target_relation = get_or_create_relation(
          database=model.database,
          schema=model.schema,
          identifier=target_table,
          type='table') -%}

  {% if not adapter.check_schema_exists(model.database, model.schema) %}
    {% do create_schema(model.database, model.schema) %}
  {% endif %}

  {{ run_hooks(pre_hooks, inside_transaction=False) }}

  {% set strategy_macro = strategy_dispatch(strategy_name) %}
  {% set strategy = strategy_macro(model, "snapshotted_data", "source_data", config, target_relation_exists) %}

  {% if not target_relation_exists %}

      {% set build_sql = build_snapshot_table(strategy, model['compiled_sql']) %}
      {% set final_sql = create_table_as(False, target_relation, build_sql) %}

  {% else %}

      {{ adapter.valid_snapshot_target(target_relation) }}

      {% set staging_table = athena__build_snapshot_staging_table(strategy, sql, target_relation) %}

      {% set missing_columns = adapter.get_missing_columns(staging_table, target_relation) %}

      {% if missing_columns %}
        {% do create_columns(target_relation, missing_columns) %}
      {% endif %}

      {% set new_snapshot_table = athena__create_new_snapshot_table(strategy, strategy_name, target_relation, staging_table) %}

      {% set final_sql = athena__snapshot_merge_sql(
            target = target_relation,
            source = new_snapshot_table
         )
      %}

  {% endif %}

  {% call statement('main') %}
      {{ final_sql }}
  {% endcall %}

  {% do persist_docs(target_relation, model) %}

  {{ run_hooks(post_hooks, inside_transaction=True) }}

  {% if staging_table is defined %}
      {% do adapter.drop_relation(staging_table) %}
  {% endif %}

  {% if new_snapshot_table is defined %}
      {% do adapter.drop_relation(new_snapshot_table) %}
  {% endif %}

  {{ run_hooks(post_hooks, inside_transaction=False) }}

  {{ return({'relations': [target_relation]}) }}

{% endmaterialization %}
