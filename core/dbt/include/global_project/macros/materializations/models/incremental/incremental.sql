
{% materialization incremental, default -%}

  {% set unique_key = config.get('unique_key') %}
  {% set target_relation = this.incorporate(type='table') %}
  {% set existing_relation = load_relation(this) %}
  {%- set temp_relation = make_temp_relation(target_relation)-%}
  {%- set intermediate_relation = make_intermediate_relation(target_relation) -%}
  {%- set backup_identifier = make_backup_relation(target_relation, backup_relation_type=none) -%}
  {%- set full_refresh_mode = (should_full_refresh()) -%}

  {% set on_schema_change = incremental_validate_on_schema_change(config.get('on_schema_change'), default='ignore') %}

  -- the temp_ and backup_ relations should not already exist in the database; get_relation
  -- will return None in that case. Otherwise, we get a relation that we can drop
  -- later, before we try to use this name for the current operation. This has to happen before
  -- BEGIN, in a separate transaction
  {% set preexisting_intermediate_relation = adapter.get_relation(identifier=intermediate_relation['identifier'],
                                                          schema=schema,
                                                          database=database) %}
  {% set preexisting_backup_relation = adapter.get_relation(identifier=backup_identifier['identifier'],
                                                            schema=schema,
                                                            database=database) %}
  {{ drop_relation_if_exists(preexisting_intermediate_relation) }}
  {{ drop_relation_if_exists(preexisting_backup_relation) }}

  {{ run_hooks(pre_hooks, inside_transaction=False) }}

  -- `BEGIN` happens here:
  {{ run_hooks(pre_hooks, inside_transaction=True) }}

  {% set to_drop = [] %}

  {# -- first check whether we want to full refresh for source view or config reasons #}
  {% set trigger_full_refresh = (full_refresh_mode or existing_relation.is_view) %}

  {% if existing_relation is none %}
      {% set build_sql = create_table_as(False, target_relation, sql) %}
  {% elif trigger_full_refresh %}
      {#-- Make sure the backup doesn't exist so we don't encounter issues with the rename below #}
      {% set intermediate_relation = existing_relation.incorporate(path={"identifier": temp_relation['identifier']}) %}
      {% set backup_relation = existing_relation.incorporate(path={"identifier": backup_identifier['identifier']}) %}

      {% set build_sql = create_table_as(False, intermediate_relation, sql) %}
      {% set need_swap = true %}
      {% do to_drop.append(backup_relation) %}
  {% else %}
    {% do run_query(create_table_as(True, temp_relation, sql)) %}
    {% do adapter.expand_target_column_types(
             from_relation=temp_relation,
             to_relation=target_relation) %}
    {#-- Process schema changes. Returns dict of changes if successful. Use source columns for upserting/merging --#}
    {% set dest_columns = process_schema_changes(on_schema_change, temp_relation, existing_relation) %}
    {% if not dest_columns %}
      {% set dest_columns = adapter.get_columns_in_relation(existing_relation) %}
    {% endif %}
    {% set build_sql = get_delete_insert_merge_sql(target_relation, temp_relation, unique_key, dest_columns) %}

  {% endif %}

  {% call statement("main") %}
      {{ build_sql }}
  {% endcall %}

  {% if need_swap %}
      {% do adapter.rename_relation(target_relation, backup_relation) %}
      {% do adapter.rename_relation(intermediate_relation, target_relation) %}
  {% endif %}

  {% do persist_docs(target_relation, model) %}

  {% if existing_relation is none or existing_relation.is_view or should_full_refresh() %}
    {% do create_indexes(target_relation) %}
  {% endif %}

  {{ run_hooks(post_hooks, inside_transaction=True) }}

  -- `COMMIT` happens here
  {% do adapter.commit() %}

  {% for rel in to_drop %}
      {% do adapter.drop_relation(rel) %}
  {% endfor %}

  {{ run_hooks(post_hooks, inside_transaction=False) }}

  {{ return({'relations': [target_relation]}) }}

{%- endmaterialization %}
