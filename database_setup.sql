/*Use UUID for sensitive tables.

https://arctype.com/blog/postgres-uuid/
https://www.postgresql.org/docs/current/uuid-ossp.html 
*/
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

/*Use custom_id for non-sensitive tables.
https://stackoverflow.com/questions/41970461/how-to-generate-a-random-unique-alphanumeric-id-of-length-n-in-postgres-9-6*/

CREATE OR REPLACE FUNCTION custom_id(size INT) RETURNS TEXT AS $$
DECLARE
  output TEXT := LEFT(md5(random()::text),size);
BEGIN
  RETURN output;
END;
$$ LANGUAGE plpgsql VOLATILE;

/*Validate email addresses.

https://dba.stackexchange.com/questions/68266/what-is-the-best-way-to-store-an-email-address-in-postgresql*/
CREATE EXTENSION citext;

CREATE DOMAIN email AS citext
  CHECK ( value ~ '^[a-zA-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$' );

/*Validate timezones.
https://justatheory.com/2007/11/postgres-timezone-validation/
*/
CREATE OR REPLACE FUNCTION is_timezone( tz TEXT ) RETURNS BOOLEAN as $$
DECLARE
    date TIMESTAMPTZ;
BEGIN
    date := now() AT TIME ZONE tz;
    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ language plpgsql STABLE;

CREATE DOMAIN timezone AS TEXT
CHECK ( is_timezone( value ) );

/*Create function to automatically update updated_time.
https://x-team.com/blog/automatic-timestamps-with-postgresql/ */
CREATE OR REPLACE FUNCTION trigger_set_updated_time()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_time = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

/***
General Notes
***/

/*Timestamp Storage
We'll use TIMESTAMPTZ for all times. This is a timestamp with timezone. 
https://medium.com/building-the-system/how-to-store-dates-and-times-in-postgresql-269bda8d6403#:~:text=TL%3BDR%2C%20Use%20PostgreSQL's%20%E2%80%9C,needs%20to%20be%20timezone%20aware.
*/


/***
Table: users

Purpose: store info on users
***/

CREATE TABLE users(
	id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    email EMAIL NOT NULL,
	first_name VARCHAR(30) NOT NULL,
	last_name VARCHAR(30) NOT NULL,
    timezone TIMEZONE NOT NULL --so that we can send messages at the right local time
);

--Each email can only be used by one user
CREATE UNIQUE INDEX UQ_users__email
	ON users (email);

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__users
BEFORE UPDATE ON users
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();


/***
Table: experiment_groups

Purpose: a user gets assigned experiments based on the experiment group(s) they belong to

Examples: Mini Experiments; Dealing with a Difficult Boss
***/

CREATE TABLE experiment_groups(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status VARCHAR(30) NOT NULL DEFAULT 'active', --we want to be able to update an experiment group for new users (e.g., update the name) while at the same time preserving data of previous experimenters. by setting it to inactive, we will not assign any new experimenters to this group but will maintain the data for previous experimenters.
    experiment_group VARCHAR(250) NOT NULL
);

--Each experiment_group with status = active has to be unique
CREATE UNIQUE INDEX UQ_experiment_groups__experiment_group
	ON experiment_groups (experiment_group) WHERE status = 'active';

--Restrict values for status
ALTER TABLE experiment_groups
    ADD CONSTRAINT check_experiment_groups__status 
    CHECK (status IN ('active', 'inactive'));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__experiment_groups
BEFORE UPDATE ON experiment_groups
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();

/***
Table: experiment_group_assignments

Purpose: Record which experiment group a user is assigned to and whether they are actively experimenting with that group.

Examples: Tristan is currently assigned to the Mini Experiments group; Tristan is currently assigned to the Dealing with a Difficult Boss group
***/

CREATE TABLE experiment_group_assignments(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id UUID NOT NULL,
    experiment_group_id VARCHAR(20) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active'
);

--Each user / experiment group should be unique
CREATE UNIQUE INDEX UQ_experiment_group_assignments
	ON experiment_group_assignments (user_id, experiment_group_id);

--Each row should be assigned to a user
ALTER TABLE experiment_group_assignments
    ADD CONSTRAINT fk_experiment_group_assignments__users
    FOREIGN KEY(user_id)
    REFERENCES users(id);

--Each row should be assigned to an experiment group
ALTER TABLE experiment_group_assignments
    ADD CONSTRAINT fk_experiment_group_assignments__experiment_groups
    FOREIGN KEY(experiment_group_id)
    REFERENCES experiment_groups(id);

--Restrict values for status
ALTER TABLE experiment_group_assignments
    ADD CONSTRAINT check_experiment_group_assignments__status
    CHECK (status IN ('active', 'paused', 'completed'));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__experiment_group_assignments
BEFORE UPDATE ON experiment_group_assignments
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();


/***
Table: experiment_sub_groups

Purpose: each experiment_group has one or more sub_groups. A sub_group is how we group experiments to assign to a user.

Examples: Week 1, Week 2, Week 3 (if a user gets a set of experiments each week); Beginner, Intermediate, and Advanced (if a user is going to get more and more difficult experiments over time)
***/

CREATE TABLE experiment_sub_groups(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    experiment_group_id VARCHAR(20) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active',
    experiment_sub_group VARCHAR(250) NOT NULL,
    assignment_order SMALLINT NOT NULL --the order in which to assign this sub_group to a user (e.g., if a user gets a set of experiments each week, we want to assign Week 1 first, then Week 2, then Week 3)
);

--Each sub_group has to be associated with an experiment_group
ALTER TABLE experiment_sub_groups
    ADD CONSTRAINT fk_experiment_sub_groups__experiment_groups
    FOREIGN KEY(experiment_group_id)
    REFERENCES experiment_groups(id)

--Each active experiment_group / experiment_sub_group combination has to be unique (we don't want to have two sub_groups with the same name)
CREATE UNIQUE INDEX UQ_experiment_sub_groups__experiment_sub_group_combo
	ON experiment_sub_groups (experiment_group_id, experiment_sub_group) WHERE status = 'active';

--Each active experiment_group / assignment order combination has to be unique (we don't want to have two sub_groups with assignment_order = 3... which one do we assign?)
CREATE UNIQUE INDEX UQ_experiment_sub_groups__experiment_group_assignment_order_combo
	ON experiment_sub_groups (experiment_group_id, assignment_order) WHERE status = 'active';

--Restrict values for status
ALTER TABLE experiment_sub_groups
    ADD CONSTRAINT check_experiment_sub_groups__status 
    CHECK (status IN ('active', 'inactive'));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__experiment_sub_groups
BEFORE UPDATE ON experiment_sub_groups
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();


/***
Table: experiment_sub_group_assignments

Purpose: Store which experiment_sub_groups have been assigned to each user and which actions to take to communicate to users. We also use this table to know what experiments to display in the Experimenter Log.

Examples: Send initial message to user about their Week 1 experiments on Monday at 9 am ET. 
***/

CREATE TABLE experiment_sub_group_assignments(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id UUID NOT NULL,
    experiment_sub_group_id VARCHAR(20) NOT NULL,
    action_type VARCHAR(30) NOT NULL, --the type of action to take (e.g., send initial message, send reminder message, send observation message)
    action_datetime TIMESTAMPTZ NOT NULL, --the date and time on which to take the action
    action_status VARCHAR(30) NOT NULL DEFAULT 'pending', --the status of the action (e.g., pending, completed)
);

--Each user should only get one action of a given type for a given experiment_sub_group
CREATE UNIQUE INDEX UQ_experiment_sub_group_assignments
	ON experiment_sub_group_assignments (user_id, experiment_sub_group_id, action_type);

--Restrict values for status
ALTER TABLE experiment_sub_group_assignments
    ADD CONSTRAINT check_experiment_sub_group_assignments__action_status
    CHECK (status IN ('pending', 'completed', 'cancelled'));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__experiment_sub_group_assignments
BEFORE UPDATE ON experiment_sub_group_assignments
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();


/***
Table: experiments

Purpose: This is the base unit of Experimenter - an experiment someone will carry out.

Note 1: Once someone has done an experiment / answered an observation prompt, we want to ensure that we always display the original text of the experiment / observation prompt in their Experimenter Log.

To accomplish this, we never update the text of an experiment group, experiment sub group, experiment, or observation prompt. Instead, we create a new version of the experiment group, experiment sub group, experiment, or observation prompt and set the prior version status = 'inactive'.

Note 2: We don't have a many-to-many relationship between experiment_groups / experiment_sub_groups / experiments because we might have the same experiment for two different experiment_groups / experiment_sub_groups, but choose to have different observation prompts depending on the context.

Examples: Ask somone "how do you really feel"?; Stay silent for ~10 minutes in a meeting and just observe.
***/

CREATE TABLE experiments(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    experiment_sub_group_id VARCHAR(20) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active',
    experiment VARCHAR NOT NULL,
);

--Each experiment has to be associated with an experiment_sub_group
ALTER TABLE experiments
    ADD CONSTRAINT fk_experiments__experiment_sub_groups
    FOREIGN KEY(experiment_sub_group_id)
    REFERENCES experiment_sub_groups(id);

--Restrict values for status
ALTER TABLE experiments
    ADD CONSTRAINT check_experiments__status
    CHECK (status IN ('active', 'inactive'));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__experiments
BEFORE UPDATE ON experiments
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();


/***
Table: observation_prompts

Purpose: Each experiment has one or more observation prompts. These are the questions we ask the user to observe and answer.

Examples: What do you want to do differently in the future?; What did you learn from this experiment?
***/

CREATE TABLE observation_prompts(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    experiment_id VARCHAR(20) NOT NULL,
    observation_prompt VARCHAR NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active',
);

--Each observation_prompt has to be associated with an experiment
ALTER TABLE observation_prompts
    ADD CONSTRAINT fk_observation_prompts__experiments
    FOREIGN KEY(experiment_id)
    REFERENCES experiments(id);

--Restrict values for status
ALTER TABLE observation_prompts
    ADD CONSTRAINT check_observation_prompts__status 
    CHECK (status IN ('active', 'inactive'));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__observation_prompts
BEFORE UPDATE ON observation_prompts
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();


/***
Table: observations

Purpose: Hold the observations for each observation prompt for each user.

Examples: What do you want to do differently in the future?; What did you learn from this experiment?
***/

CREATE TABLE observations(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id UUID NOT NULL,
    observation_prompt_id VARCHAR(20) NOT NULL,
    observation VARCHAR NOT NULL,
);

--Each observation has to be associated with an observation_prompt
ALTER TABLE observations
    ADD CONSTRAINT fk_observations__observation_prompts
    FOREIGN KEY(observation_prompt_id)
    REFERENCES observation_prompts(id);

--Each observation has to be associated with a user
ALTER TABLE observations
    ADD CONSTRAINT fk_observations__users
    FOREIGN KEY(user_id)
    REFERENCES users(id);

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__observations
BEFORE UPDATE ON observations
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();


/***
Table: user_lookups

Purpose: Provide a public facing id that can be used to lookup a user_id without exposing the actual user_id. We can set this string inactive at any point if it is compromised or no longer needed.

***/

CREATE TABLE user_lookups(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    public_user_id VARCHAR(6) NOT NULL DEFAULT custom_id(6),
    user_id UUID NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active',
);

--Each public_user_id must be unique
CREATE UNIQUE INDEX UQ_user_lookups__public_user_id
	ON user_lookups (public_user_id);

--Each user_id can only have one active row (we expect to have multiple inactive rows for each user_id)
CREATE UNIQUE INDEX UQ_user_lookups__user_id
	ON user_lookups (user_id) WHERE status = 'active';

--Each user_lookup has to be associated with a user
ALTER TABLE user_lookups
    ADD CONSTRAINT fk_user_lookups__users
    FOREIGN KEY(user_id)
    REFERENCES users(id);

--Restrict values for status
ALTER TABLE user_lookups
    ADD CONSTRAINT check_user_lookups__status 
    CHECK (status IN ('active', 'inactive'));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__user_lookups
BEFORE UPDATE ON user_lookups
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();




/***
TESTING
***/

--Test email uniqueness ADD CONSTRAINT
INSERT INTO users(email, first_name, last_name, timezone) 
VALUES
	('santa@gmail.com', 'Santa', 'Claus', 'America/New_York'),
	('santa@gmail.com', 'Santa 2', 'Claus', 'America/New_York');

--Test email validity ADD CONSTRAINT
INSERT INTO users(email, first_name, last_name, timezone) 
VALUES
	('santa@@gmail.com', 'Santa', 'Claus', 'America/New_York');

--Test timezone validity ADD CONSTRAINT
INSERT INTO users(email, first_name, last_name, timezone) 
VALUES
	('santa@gmail.com', 'Santa', 'Claus', 'America/New_Yorkss');

/*Test updated time*/
INSERT INTO users(email, first_name, last_name, timezone) 
VALUES
	('santa@gmail.com', 'Santa', 'Claus', 'America/New_York'),
	('santaclause@gmail.com', 'Santa 2', 'Claus', 'America/Chicago');

-- Wait for a second, then run
UPDATE users
SET first_name = 'Santa 2nd'
WHERE first_name = 'Santa 2';

--Check inserts, update time
SELECT * FROM users;





