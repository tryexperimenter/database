/*Functions that we use in our Postgresql database and call with Python.

Supabase documentation: https://supabase.com/docs/guides/database/functions

Example Python call: response = supabase_client.rpc(fn = "get_user", params = {"email":"tristanzucker@gmail.comd"}).execute()
*/


/*Return all users
Python call to postgres function with no parameters given
response = supabase_client.rpc(fn = "users", params = {}).execute()
*/
CREATE OR REPLACE FUNCTION users()
RETURNS setof users
LANGUAGE SQL
AS $$
  SELECT * FROM users;
$$;


/*Return a user based on their email address
Python call to get_user() postgres function with email parameter given
response = supabase_client.rpc(fn = "get_user", params = {"email":"santaclaus@gmail.com"}).execute()
*/
CREATE OR REPLACE FUNCTION get_user(email TEXT)
RETURNS setof users
LANGUAGE SQL
AS $$
  SELECT * FROM users WHERE email = get_user.email;
$$;



/***
Experimenter Log Data
***/

CREATE OR REPLACE FUNCTION get_experimenter_log_data(public_user_id TEXT)
RETURNS TABLE (
    first_name TEXT, 
	display_datetime TIMESTAMPTZ,
	experiment_group_id TEXT,
 	experiment_group TEXT, 
	experiment_sub_group_id TEXT,
 	experiment_sub_group TEXT, 
	experiment_id TEXT,
 	experiment TEXT, 
	observation_prompt_id TEXT,
 	observation_prompt TEXT, 
	observation_id TEXT,
	observation TEXT)
LANGUAGE SQL
AS $$

/*
Case 1: Public_user_id is not found / not active -- returns no rows
Case 2: User has no experiments -- returns one row with just user's info
Case 3: User has experiments -- returns rows for every experiment / observation prompt combination
Case 4: User has experiments and has observations -- returns rows for every experiment / observation prompt combination with observation column filled out
*/

-- User info associated with the public_user_id
WITH identified_user AS
(SELECT
 	u.id AS user_id,
	u.first_name
FROM 
	user_lookups ul, 
	users u
WHERE
	ul.public_user_id = get_experimenter_log_data.public_user_id AND -- restrict to the public_user_id
    ul.status = 'active' AND -- ensure the public_user_id is active 
    u.id = ul.user_id), -- restrict to the user associated with the public_user_id

-- All of the experiments, etc. assigned to the user
assigned_experiments AS (
SELECT
	iu.user_id,
	eg.id AS experiment_group_id,
 	eg.experiment_group, 
	esg.id AS experiment_sub_group_id,
 	esg.experiment_sub_group, 
	e.id AS experiment_id,
 	e.experiment, 
	op.id AS observation_prompt_id,
 	op.observation_prompt, 
	esga.action_datetime AS display_datetime,
	e.display_order AS e_display_order,
	op.display_order AS op_display_order
FROM
	identified_user iu,
	experiment_sub_group_assignments esga, 
	experiment_sub_groups esg, 
	experiment_groups eg,
	experiments e,
	observation_prompts op
WHERE
	esga.user_id = iu.user_id AND esga.action_type = 'display_experiment_sub_group' AND esga.action_status = 'completed' AND -- restrict to just the experiment_sub_group_assignments for the user that are flagged to be displayed
	esga.action_datetime < NOW() AT TIME ZONE 'UTC' AND -- restrict to just the experiment_sub_group_assignments that are supposed to be displayed starting now or earlier
	esg.id = esga.experiment_sub_group_id AND --restrict to just the relevant experiment_sub_groups
	eg.id = esg.experiment_group_id AND -- restrict to just the relevant experiment_groups
	e.experiment_sub_group_id = esg.id AND -- restrict to just the relevant experiments
	op.experiment_id = e.id -- restrict to just the relevant observation prompts
),

-- All of the observations made by the user
user_observations AS (
SELECT 
	o.observation_prompt_id,
	o.id AS observation_id,
	o.observation
FROM
	assigned_experiments ae,
	observations o
WHERE
	o.observation_prompt_id = ae.observation_prompt_id AND -- restrict to observations for relevant observation prompts
	o.user_id = ae.user_id AND -- restrict to observations by the user
	o.status = 'active' -- restrict to active observations
)

--Combine user info, experiment info, and observations
--Note: we do left joins so that we return data if there is an identified user but no experiments (experiments, but no observations)
SELECT
	iu.first_name, 
	ae.display_datetime,
	ae.experiment_group_id,
 	ae.experiment_group, 
	ae.experiment_sub_group_id,
 	ae.experiment_sub_group, 
	ae.experiment_id,
 	ae.experiment, 
	ae.observation_prompt_id,
 	ae.observation_prompt, 
	uo.observation_id,
	uo.observation
FROM identified_user iu
LEFT JOIN assigned_experiments ae ON iu.user_id = ae.user_id
LEFT JOIN user_observations uo ON ae.observation_prompt_id = uo.observation_prompt_id
ORDER BY
	display_datetime,
	e_display_order,
	op_display_order;

$$;

