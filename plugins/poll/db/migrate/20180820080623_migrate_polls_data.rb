class MigratePollsData < ActiveRecord::Migration[5.2]
  def up
    execute <<~SQL
      WITH extracted_polls AS (
          SELECT post_id
               , created_at
               , updated_at
               , p.key "poll_name"
               , p.value "poll"
            FROM post_custom_fields pcf
               , json_each(value::json) p
           WHERE name = 'polls'
           ORDER BY post_id
      ), migrated_polls AS (
          INSERT INTO polls (post_id, name, type, status, close_at, visibility, min, max, step, created_at, updated_at)
          SELECT post_id
               , poll->>'name'
               , COALESCE(NULLIF(SUBSTRING(poll->>'type', 'regular|multiple|number'), ''), 'regular')
               , poll->>'status'
               , CASE WHEN poll->>'close' ~* '^20\d\d-\d\d-\d\d.\d\d:\d\d:\d\d(\.\d\d\dZ)?$' THEN to_timestamp(poll->>'close', 'YYYY-MM-DD hh24:mi:ss')::timestamp without time zone ELSE NULL END
               , CASE WHEN (COALESCE(poll->>'public', 'f'))::boolean THEN 'public' ELSE 'private' END
               , (poll->>'min')::int
               , (poll->>'max')::int
               , CASE WHEN ROUND((poll->>'step')::real) < 1 THEN 1 ELSE ROUND((poll->>'step')::real) END
               , created_at
               , updated_at
            FROM extracted_polls
       RETURNING id, name, post_id
      ), migrated_poll_options AS (
          INSERT INTO poll_options(poll_id, digest, html, created_at, updated_at)
          SELECT mp.id
               , option->>'id'
               , option->>'html'
               , created_at
               , updated_at
            FROM extracted_polls ep
               , migrated_polls mp
               , json_array_elements(poll->'options') option
           WHERE ep.post_id = mp.post_id
             AND ep.poll_name = mp.name
       RETURNING id, poll_id, digest
      ), extracted_votes AS (
          SELECT post_id
               , poll_name
               , user_id
               , TRIM(value::text, '"') "digest"
            FROM (
              SELECT post_id
                   , user_id
                   , key poll_name
                   , value "options"
                FROM (
                  SELECT post_id
                       , v.key::int user_id
                       , v.value "votes"
                    FROM post_custom_fields pcf
                       , json_each(value::json) v
                   WHERE name = 'polls-votes'
                ) v, json_each(v.votes)
            ) o, json_array_elements(o.options)
      )
      INSERT INTO poll_votes (poll_id, poll_option_id, user_id, created_at, updated_at)
      SELECT mp.id
           , mpo.id
           , ev.user_id
           , now()
           , now()
        FROM extracted_votes ev
           , users u
           , migrated_polls mp
           , migrated_poll_options mpo
       WHERE u.id = ev.user_id
         AND mp.post_id = ev.post_id
         AND mp.name = ev.poll_name
         AND mpo.poll_id = mp.id
         AND mpo.digest = ev.digest
    SQL
  end

  def down
  end
end
