-- Quán Nhậu Dzô: bảng xếp hạng "Đêm thử thách mỗi ngày"
-- Chạy toàn bộ file này một lần trong Supabase: SQL Editor -> New query -> dán -> Run.
-- Chạy lại cũng được: file tự xoá hàm cũ và giữ nguyên dữ liệu điểm.
--
-- Mô hình bảo mật: trình duyệt chỉ dùng anon key (công khai). Mọi bảng bật RLS và
-- không có policy nào, nên anon không đọc/ghi bảng trực tiếp được. Trình duyệt chỉ
-- gọi được các hàm qnd_* bên dưới; các hàm này tự kiểm tra mã bí mật người chơi,
-- thời gian chơi, trần điểm và số lượt.

create table if not exists qnd_players (
  id          uuid primary key default gen_random_uuid(),
  secret_hash text not null,
  nick        text not null,
  banned      boolean not null default false,
  created_at  timestamptz not null default now()
);

create table if not exists qnd_runs (
  id           uuid primary key default gen_random_uuid(),
  player_id    uuid not null references qnd_players(id) on delete cascade,
  day          date not null,
  started_at   timestamptz not null default now(),
  submitted_at timestamptz,
  score        bigint,
  stats        jsonb,
  flag         text
);
create index if not exists qnd_runs_player_day on qnd_runs(player_id, day);

create table if not exists qnd_best (
  day        date not null,
  player_id  uuid not null references qnd_players(id) on delete cascade,
  score      bigint not null,
  rating     numeric(3,1),
  combo      int,
  attempts   int not null default 1,
  updated_at timestamptz not null default now(),
  primary key (day, player_id)
);
create index if not exists qnd_best_day_score on qnd_best(day, score desc);

alter table qnd_players enable row level security;
alter table qnd_runs    enable row level security;
alter table qnd_best    enable row level security;
revoke all on qnd_players, qnd_runs, qnd_best from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on qnd_players, qnd_runs, qnd_best from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on qnd_players, qnd_runs, qnd_best from authenticated';
  end if;
end $$;

-- ---------- luật chống gian lận (chỉnh ở đây) ----------
-- Một đêm thử thách cần ít nhất ~90 giây thật (đóng cửa lúc 360 phút game, 4 phút game/giây).
create or replace function qnd_cfg() returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'min_seconds',  80,        -- nộp sớm hơn thế là bị từ chối
    'max_seconds',  3600,      -- lượt mở quá 1 giờ thì hết hạn
    'max_score',   12000000,   -- trần lãi một đêm (đồng); bot phản xạ 0,3 giây đạt tối đa ~9 triệu
    'min_score',   -5000000,   -- sàn lỗ một đêm (đồng)
    'max_runs_day', 30         -- số lượt mỗi người mỗi ngày
  );
$$;

-- Ngày theo giờ Việt Nam
create or replace function qnd_today() returns date language sql stable as $$
  select (now() at time zone 'Asia/Ho_Chi_Minh')::date;
$$;

-- Đề của ngày: mô hình xoay vòng 4 ngày, khu phố xoay vòng 5 ngày (20 ngày mới lặp lại cặp).
-- Phải khớp với hàm chDef() trong index.html.
create or replace function qnd_model_of(p_day date) returns text language sql immutable as $$
  select (array['nhau','trasua','lapxuong','comtam'])[((p_day - date '2026-01-01') % 4 + 4) % 4 + 1];
$$;

-- ---------- tiện ích ----------
create or replace function qnd_hash(p text) returns text language sql immutable as $$
  select encode(sha256(convert_to(p, 'UTF8')), 'hex');
$$;

create or replace function qnd_auth(p_id uuid, p_secret text) returns qnd_players
language plpgsql stable security definer set search_path = public as $$
declare v qnd_players;
begin
  select * into v from qnd_players where id = p_id;
  if v.id is null or v.secret_hash <> qnd_hash(coalesce(p_secret, '')) then
    raise exception 'QND_AUTH';
  end if;
  if v.banned then raise exception 'QND_BANNED'; end if;
  return v;
end $$;

create or replace function qnd_clean_nick(p_nick text) returns text
language plpgsql immutable as $$
declare n text := regexp_replace(btrim(coalesce(p_nick, '')), '\s+', ' ', 'g');
        l text;
begin
  if char_length(n) < 2 or char_length(n) > 20 then raise exception 'QND_NICK_LEN'; end if;
  if n !~ '^[A-Za-z0-9À-ỹ _.\-]+$' then raise exception 'QND_NICK_CHARS'; end if;
  l := lower(n);
  if l ~* '(lồn|buồi|cặc|địt|đụ|đéo|đĩ|chịch|nứng|lìn)'
     or l ~* '(^|[^a-z0-9À-ỹ])(dm|đm|dcm|đcm|dkm|vcl|vkl|vl|clgt|cc|dmm|đmm|loz|lol|du ma|dit|deo|admin|qtv)([^a-z0-9À-ỹ]|$)'
  then raise exception 'QND_NICK_BAD'; end if;
  return n;
end $$;

-- ---------- API cho trình duyệt ----------
drop function if exists qnd_register(text);
create function qnd_register(p_nick text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_secret text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
        v_id uuid;
        v_nick text := qnd_clean_nick(p_nick);
begin
  insert into qnd_players(secret_hash, nick) values (qnd_hash(v_secret), v_nick) returning id into v_id;
  return jsonb_build_object('id', v_id, 'secret', v_secret, 'nick', v_nick);
end $$;

drop function if exists qnd_rename(uuid, text, text);
create function qnd_rename(p_id uuid, p_secret text, p_nick text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v qnd_players := qnd_auth(p_id, p_secret);
        v_nick text := qnd_clean_nick(p_nick);
begin
  update qnd_players set nick = v_nick where id = v.id;
  return jsonb_build_object('nick', v_nick);
end $$;

drop function if exists qnd_start(uuid, text);
create function qnd_start(p_id uuid, p_secret text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v qnd_players := qnd_auth(p_id, p_secret);
        d date := qnd_today();
        n int;
        r uuid;
begin
  select count(*) into n from qnd_runs where player_id = v.id and day = d;
  if n >= (qnd_cfg()->>'max_runs_day')::int then raise exception 'QND_MAX_RUNS'; end if;
  insert into qnd_runs(player_id, day) values (v.id, d) returning id into r;
  return jsonb_build_object('run', r, 'day', d, 'model', qnd_model_of(d), 'attempt', n + 1);
end $$;

drop function if exists qnd_submit(uuid, text, uuid, bigint, jsonb);
create function qnd_submit(p_id uuid, p_secret text, p_run uuid, p_score bigint, p_stats jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v qnd_players := qnd_auth(p_id, p_secret);
        cfg jsonb := qnd_cfg();
        run qnd_runs;
        secs numeric;
        rt numeric := least(5, greatest(1, coalesce((p_stats->>'rating')::numeric, 0)));
        cb int := least(999, greatest(0, coalesce((p_stats->>'combo')::int, 0)));
        prev qnd_best;
        improved boolean := false;
        v_rank int; v_total int; v_best bigint;
begin
  select * into run from qnd_runs where id = p_run and player_id = v.id for update;
  if run.id is null then raise exception 'QND_RUN'; end if;
  if run.submitted_at is not null then raise exception 'QND_RUN_USED'; end if;
  secs := extract(epoch from now() - run.started_at);
  if secs > (cfg->>'max_seconds')::numeric then
    update qnd_runs set submitted_at = now(), score = p_score, stats = p_stats, flag = 'expired' where id = run.id;
    return jsonb_build_object('error', 'QND_EXPIRED');
  end if;
  if secs < (cfg->>'min_seconds')::numeric then
    update qnd_runs set submitted_at = now(), score = p_score, stats = p_stats, flag = 'too_fast' where id = run.id;
    return jsonb_build_object('error', 'QND_TOO_FAST');
  end if;
  if p_score > (cfg->>'max_score')::bigint or p_score < (cfg->>'min_score')::bigint or p_score % 1000 <> 0 then
    update qnd_runs set submitted_at = now(), score = p_score, stats = p_stats, flag = 'score' where id = run.id;
    return jsonb_build_object('error', 'QND_SCORE');
  end if;

  update qnd_runs set submitted_at = now(), score = p_score, stats = p_stats where id = run.id;

  select * into prev from qnd_best where day = run.day and player_id = v.id for update;
  if prev.player_id is null then
    insert into qnd_best(day, player_id, score, rating, combo) values (run.day, v.id, p_score, rt, cb);
    improved := true;
  elsif p_score > prev.score then
    update qnd_best set score = p_score, rating = rt, combo = cb, attempts = attempts + 1, updated_at = now()
     where day = run.day and player_id = v.id;
    improved := true;
  else
    update qnd_best set attempts = attempts + 1 where day = run.day and player_id = v.id;
  end if;

  select score into v_best from qnd_best where day = run.day and player_id = v.id;
  select count(*) + 1 into v_rank from qnd_best b join qnd_players p on p.id = b.player_id
   where b.day = run.day and not p.banned and b.score > v_best;
  select count(*) into v_total from qnd_best b join qnd_players p on p.id = b.player_id
   where b.day = run.day and not p.banned;
  return jsonb_build_object('day', run.day, 'score', p_score, 'best', v_best, 'improved', improved,
                            'rank', v_rank, 'total', v_total);
end $$;

-- p_kind: 'day' (bảng một ngày), 'week' (cộng điểm cao nhất mỗi ngày từ thứ Hai),
--         'model' (điểm một đêm cao nhất trong 28 ngày, chỉ các ngày có đề là p_model)
drop function if exists qnd_board(text, date, text, uuid, int);
create function qnd_board(p_kind text, p_day date default null, p_model text default null,
                          p_player uuid default null, p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_day, qnd_today());
        lim int := least(100, greatest(1, coalesce(p_limit, 50)));
        res jsonb;
begin
  with src as (
    select b.player_id, p.nick, b.score, b.rating, b.combo, b.attempts, b.updated_at
      from qnd_best b join qnd_players p on p.id = b.player_id
     where p_kind = 'day' and b.day = d and not p.banned
    union all
    select b.player_id, min(p.nick), sum(greatest(b.score, 0))::bigint, round(avg(b.rating), 1),
           max(b.combo), count(*)::int, max(b.updated_at)
      from qnd_best b join qnd_players p on p.id = b.player_id
     where p_kind = 'week' and not p.banned
       and b.day between date_trunc('week', d)::date and date_trunc('week', d)::date + 6
     group by b.player_id
    union all
    select * from (
      select distinct on (b.player_id) b.player_id, p.nick, b.score, b.rating, b.combo, b.attempts, b.updated_at
        from qnd_best b join qnd_players p on p.id = b.player_id
       where p_kind = 'model' and not p.banned and qnd_model_of(b.day) = p_model
         and b.day between d - 27 and d
       order by b.player_id, b.score desc, b.updated_at
    ) m
  ), ranked as (
    select *, rank() over (order by score desc) as rk,
           row_number() over (order by score desc, updated_at) as rn
      from src
  )
  select jsonb_build_object(
    'kind', p_kind, 'day', d, 'model', p_model,
    'total', (select count(*) from ranked),
    'top', coalesce((select jsonb_agg(jsonb_build_object('rank', rk, 'nick', nick, 'score', score, 'rating', rating,
                                                          'combo', combo, 'n', attempts, 'me', player_id = p_player) order by rn)
                       from ranked where rn <= lim), '[]'::jsonb),
    'me', (select jsonb_build_object('rank', rk, 'nick', nick, 'score', score, 'rating', rating, 'combo', combo, 'n', attempts)
             from ranked where player_id = p_player)
  ) into res;
  return res;
end $$;

-- Chỉ cho trình duyệt gọi 5 hàm API
revoke all on function qnd_register(text), qnd_rename(uuid, text, text), qnd_start(uuid, text),
  qnd_submit(uuid, text, uuid, bigint, jsonb), qnd_board(text, date, text, uuid, int),
  qnd_auth(uuid, text), qnd_clean_nick(text), qnd_hash(text), qnd_cfg(), qnd_today(), qnd_model_of(date) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant execute on function qnd_register(text), qnd_rename(uuid, text, text), qnd_start(uuid, text),
      qnd_submit(uuid, text, uuid, bigint, jsonb), qnd_board(text, date, text, uuid, int) to anon, authenticated';
  end if;
end $$;

-- ---------- dành cho chủ game (chạy tay trong SQL Editor) ----------
-- Xem các lượt bị đánh dấu:      select * from qnd_runs where flag is not null order by started_at desc;
-- Khoá một người chơi gian lận:  update qnd_players set banned = true where nick = 'Tên';
-- Xoá điểm một ngày của ai đó:   delete from qnd_best where day = '2026-10-17' and player_id = '...';
