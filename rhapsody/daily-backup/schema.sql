


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."get_admin_dashboard_data"("p_date_filter" "text" DEFAULT 'All Time'::"text", "p_type_filter" "text" DEFAULT 'All Types'::"text", "p_org_filter" "text" DEFAULT 'All Organisers'::"text", "p_funds_filter" "text" DEFAULT 'All Destinations'::"text") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_result JSON;
  v_start_date TIMESTAMP;
BEGIN
  IF p_date_filter = 'Today' THEN v_start_date := CURRENT_DATE;
  ELSIF p_date_filter = 'Last 7 Days' THEN v_start_date := CURRENT_DATE - INTERVAL '7 days';
  ELSIF p_date_filter = 'This Month' THEN v_start_date := DATE_TRUNC('month', CURRENT_DATE);
  ELSE v_start_date := '-infinity'::TIMESTAMP;
  END IF;

  WITH filtered_tickets AS (
    SELECT * FROM tickets
    WHERE created_at >= v_start_date
      AND (p_type_filter = 'All Types' OR type = p_type_filter)
      AND (p_org_filter = 'All Organisers' OR sold_by = p_org_filter)
      AND (p_funds_filter = 'All Destinations' OR funds_destination = LOWER(p_funds_filter))
  ),
  overall_metrics AS (
    SELECT
      COALESCE(SUM(price * quantity), 0) as total_revenue,
      COALESCE(SUM(CASE WHEN funds_destination = 'trust' THEN price * quantity ELSE 0 END), 0) as trust_revenue,
      COALESCE(SUM(CASE WHEN funds_destination = 'organizer' THEN price * quantity ELSE 0 END), 0) as organizer_revenue,
      COALESCE(SUM(quantity), 0) as total_tickets,
      COALESCE(SUM(CASE WHEN status != 'cancelled' AND (type ILIKE '%Platinum%' OR type ILIKE '%Student%') AND type NOT ILIKE '%Donor%' THEN quantity ELSE 0 END), 0) as scannable_tickets,
      COALESCE(SUM(CASE WHEN status = 'checked_in' AND (type ILIKE '%Platinum%' OR type ILIKE '%Student%') AND type NOT ILIKE '%Donor%' THEN quantity ELSE 0 END), 0) as checked_in,
      COALESCE(SUM(CASE WHEN status = 'cancelled' THEN quantity ELSE 0 END), 0) as cancelled_count
    FROM filtered_tickets
  ),
  whatsapp_stats AS (
    SELECT
      COALESCE(COUNT(*) FILTER (WHERE whatsapp_status = 'sent'), 0) as sent,
      COALESCE(COUNT(*) FILTER (WHERE whatsapp_status = 'failed'), 0) as failed,
      COALESCE(COUNT(*) FILTER (WHERE whatsapp_status IS NULL OR whatsapp_status = 'not_sent'), 0) as not_sent
    FROM filtered_tickets
  ),
  chart_data AS (
    SELECT type as name, SUM(quantity) as sold, SUM(price * quantity) as revenue
    FROM filtered_tickets GROUP BY type
  ),
  leaderboard AS (
    SELECT
      sold_by as name,
      COALESCE(SUM(CASE WHEN type ILIKE '%Platinum%' THEN quantity ELSE 0 END), 0) as platinum,
      COALESCE(SUM(CASE WHEN type ILIKE '%Donor%' THEN quantity ELSE 0 END), 0) as donor,
      COALESCE(SUM(CASE WHEN type ILIKE '%Student%' THEN quantity ELSE 0 END), 0) as student,
      COALESCE(SUM(CASE WHEN type = 'VIP' THEN quantity ELSE 0 END), 0) as vip,
      COALESCE(SUM(quantity), 0) as total,
      COALESCE(SUM(price * quantity), 0) as revenue
    FROM filtered_tickets
    WHERE sold_by IS NOT NULL GROUP BY sold_by
  )
  SELECT json_build_object(
    'metrics', (SELECT row_to_json(overall_metrics.*) FROM overall_metrics),
    'whatsapp', (SELECT row_to_json(whatsapp_stats.*) FROM whatsapp_stats),
    'chart_data', (SELECT json_agg(chart_data.*) FROM chart_data),
    'leaderboard', (SELECT json_agg(leaderboard.*) FROM leaderboard)
  ) INTO v_result;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_admin_dashboard_data"("p_date_filter" "text", "p_type_filter" "text", "p_org_filter" "text", "p_funds_filter" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."populate_vip_sequence"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.type = 'VIP' THEN
        NEW.vip_sequence_number := nextval('vip_ticket_sequence');
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."populate_vip_sequence"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."broadcasts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "title" "text" NOT NULL,
    "message" "text" NOT NULL,
    "broadcast_type" "text" DEFAULT 'text'::"text" NOT NULL,
    "target_type" "text" NOT NULL,
    "target_categories" "text"[],
    "image_url" "text",
    "survey_url" "text",
    "scheduled_at" timestamp with time zone,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "total_recipients" integer DEFAULT 0,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb"
);


ALTER TABLE "public"."broadcasts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "date" "date" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "name" "text",
    "phone" "text",
    "roles" "text"[] DEFAULT '{organiser}'::"text"[],
    "password" "text",
    "pass_targets" "jsonb"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."profiles"."pass_targets" IS 'JSON map of pass display name → numeric target; merged with app defaults when null or partial';



CREATE TABLE IF NOT EXISTS "public"."ticket_checkins" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ticket_id" "uuid" NOT NULL,
    "count" integer NOT NULL,
    "checked_in_name" "text",
    "staff_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "ticket_checkins_count_check" CHECK (("count" > 0))
);


ALTER TABLE "public"."ticket_checkins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tickets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid",
    "type" "text" NOT NULL,
    "price" numeric NOT NULL,
    "status" "text" DEFAULT 'pending'::"text",
    "purchaser_name" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "sold_by" "text",
    "purchaser_phone" "text",
    "funds_destination" "text",
    "quantity" integer DEFAULT 1 NOT NULL,
    "bank_txn_id" "text",
    "whatsapp_status" "text" DEFAULT 'not_sent'::"text",
    "whatsapp_error" "text",
    "last_whatsapp_at" timestamp with time zone,
    "checked_in_count" integer DEFAULT 0,
    "id_text" "text" GENERATED ALWAYS AS (("id")::"text") STORED,
    "sequence_number" bigint NOT NULL,
    "whatsapp_opt_in" boolean DEFAULT true,
    "wa_message_id" "text",
    "vip_sequence_number" integer,
    CONSTRAINT "tickets_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'booked'::"text", 'ticket_issued'::"text", 'checked_in'::"text", 'cancelled'::"text"]))),
    CONSTRAINT "tickets_type_check" CHECK (("type" = ANY (ARRAY['Platinum'::"text", 'Donor'::"text", 'Student'::"text", 'VIP'::"text"])))
);


ALTER TABLE "public"."tickets" OWNER TO "postgres";


COMMENT ON COLUMN "public"."tickets"."quantity" IS 'Passes in this sale (single transaction row). Price is per pass.';



ALTER TABLE "public"."tickets" ALTER COLUMN "sequence_number" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."tickets_sequence_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE SEQUENCE IF NOT EXISTS "public"."vip_ticket_sequence"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."vip_ticket_sequence" OWNER TO "postgres";


ALTER TABLE ONLY "public"."broadcasts"
    ADD CONSTRAINT "broadcasts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ticket_checkins"
    ADD CONSTRAINT "ticket_checkins_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "unique_phone" UNIQUE ("phone");



CREATE INDEX "idx_ticket_checkins_ticket_id" ON "public"."ticket_checkins" USING "btree" ("ticket_id");



CREATE INDEX "idx_tickets_created_at" ON "public"."tickets" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_tickets_id_text" ON "public"."tickets" USING "btree" ("id_text");



CREATE INDEX "idx_tickets_purchaser_name_trgm" ON "public"."tickets" USING "gin" ("purchaser_name" "public"."gin_trgm_ops");



CREATE INDEX "idx_tickets_purchaser_phone" ON "public"."tickets" USING "btree" ("purchaser_phone");



CREATE INDEX "idx_tickets_sequence_number" ON "public"."tickets" USING "btree" ("sequence_number");



CREATE INDEX "idx_tickets_sold_by" ON "public"."tickets" USING "btree" ("sold_by");



CREATE INDEX "idx_tickets_wa_message_id" ON "public"."tickets" USING "btree" ("wa_message_id");



CREATE INDEX "idx_tickets_whatsapp_status" ON "public"."tickets" USING "btree" ("whatsapp_status");



CREATE OR REPLACE TRIGGER "trg_populate_vip_sequence" BEFORE INSERT ON "public"."tickets" FOR EACH ROW EXECUTE FUNCTION "public"."populate_vip_sequence"();



ALTER TABLE ONLY "public"."ticket_checkins"
    ADD CONSTRAINT "ticket_checkins_ticket_id_fkey" FOREIGN KEY ("ticket_id") REFERENCES "public"."tickets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tickets"
    ADD CONSTRAINT "tickets_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



CREATE POLICY "Allow anonymous inserts" ON "public"."profiles" FOR INSERT WITH CHECK (true);



CREATE POLICY "Allow anonymous reads on profiles" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "Allow full access for authenticated users on events" ON "public"."events" TO "authenticated" USING (true);



CREATE POLICY "Allow full access for authenticated users on profiles" ON "public"."profiles" TO "authenticated" USING (true);



CREATE POLICY "Allow full access for authenticated users on tickets" ON "public"."tickets" TO "authenticated" USING (true);



CREATE POLICY "Allow read access for anyone" ON "public"."events" FOR SELECT USING (true);



CREATE POLICY "Allow read access for anyone" ON "public"."tickets" FOR SELECT USING (true);



ALTER TABLE "public"."broadcasts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "broadcasts_insert_anon" ON "public"."broadcasts" FOR INSERT TO "authenticated", "anon" WITH CHECK (true);



CREATE POLICY "broadcasts_manage_anon" ON "public"."broadcasts" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "broadcasts_select_anon" ON "public"."broadcasts" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_delete_anon" ON "public"."profiles" FOR DELETE TO "authenticated", "anon" USING (true);



CREATE POLICY "profiles_insert_anon" ON "public"."profiles" FOR INSERT TO "authenticated", "anon" WITH CHECK (true);



CREATE POLICY "profiles_select_anon" ON "public"."profiles" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "profiles_update_anon" ON "public"."profiles" FOR UPDATE TO "authenticated", "anon" USING (true);



CREATE POLICY "public_insert_checkins" ON "public"."ticket_checkins" FOR INSERT WITH CHECK (true);



CREATE POLICY "public_select_checkins" ON "public"."ticket_checkins" FOR SELECT USING (true);



ALTER TABLE "public"."ticket_checkins" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ticket_checkins_anon_insert" ON "public"."ticket_checkins" FOR INSERT TO "authenticated", "anon" WITH CHECK (true);



CREATE POLICY "ticket_checkins_anon_select" ON "public"."ticket_checkins" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "ticket_checkins_anon_update" ON "public"."ticket_checkins" FOR UPDATE TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."tickets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tickets_anon_delete" ON "public"."tickets" FOR DELETE TO "authenticated", "anon" USING (true);



CREATE POLICY "tickets_anon_insert" ON "public"."tickets" FOR INSERT TO "authenticated", "anon" WITH CHECK (true);



CREATE POLICY "tickets_anon_select" ON "public"."tickets" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "tickets_anon_update" ON "public"."tickets" FOR UPDATE TO "authenticated", "anon" USING (true);





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."get_admin_dashboard_data"("p_date_filter" "text", "p_type_filter" "text", "p_org_filter" "text", "p_funds_filter" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_admin_dashboard_data"("p_date_filter" "text", "p_type_filter" "text", "p_org_filter" "text", "p_funds_filter" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_dashboard_data"("p_date_filter" "text", "p_type_filter" "text", "p_org_filter" "text", "p_funds_filter" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."populate_vip_sequence"() TO "anon";
GRANT ALL ON FUNCTION "public"."populate_vip_sequence"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."populate_vip_sequence"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "postgres";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "anon";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "service_role";



GRANT ALL ON FUNCTION "public"."show_limit"() TO "postgres";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "anon";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "service_role";


















GRANT ALL ON TABLE "public"."broadcasts" TO "anon";
GRANT ALL ON TABLE "public"."broadcasts" TO "authenticated";
GRANT ALL ON TABLE "public"."broadcasts" TO "service_role";



GRANT ALL ON TABLE "public"."events" TO "anon";
GRANT ALL ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."ticket_checkins" TO "anon";
GRANT ALL ON TABLE "public"."ticket_checkins" TO "authenticated";
GRANT ALL ON TABLE "public"."ticket_checkins" TO "service_role";



GRANT ALL ON TABLE "public"."tickets" TO "anon";
GRANT ALL ON TABLE "public"."tickets" TO "authenticated";
GRANT ALL ON TABLE "public"."tickets" TO "service_role";



GRANT ALL ON SEQUENCE "public"."tickets_sequence_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."tickets_sequence_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."tickets_sequence_number_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."vip_ticket_sequence" TO "anon";
GRANT ALL ON SEQUENCE "public"."vip_ticket_sequence" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."vip_ticket_sequence" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";



































