/*Allow for UUID as Primary Key

While it could be overkill for non-sensitive tables, we’re going to default to using a Universally Unique ID as our primary keys. Some background info is:

https://arctype.com/blog/postgres-uuid/
https://www.postgresql.org/docs/current/uuid-ossp.html 
*/
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

/*Validate email addresses.

https://dba.stackexchange.com/questions/68266/what-is-the-best-way-to-store-an-email-address-in-postgresql*/
CREATE EXTENSION citext;

CREATE DOMAIN email AS citext
  CHECK ( value ~ '^[a-zA-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$' );


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
Table: users

Purpose: store info on users
***/

CREATE TABLE users(
	id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status VARCHAR(30) NOT NULL DEFAULT 'active',
    email EMAIL NOT NULL,
	first_name VARCHAR(30) NOT NULL,
	last_name VARCHAR(30) NOT NULL,
    preferred_first_name VARCHAR(30),
    timezone VARCHAR(30) NOT NULL,
);

--Each email can only be used by one user
CREATE UNIQUE INDEX UQ_users__email
	ON users (email);

--Restrict values for status
ALTER TABLE users
    ADD CONSTRAINT check_users__status
    CHECK (status IN ('active', 'inactive'));

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
	id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status VARCHAR(30) NOT NULL DEFAULT 'active',
    experiment_group VARCHAR(250) NOT NULL,
);

--Each experiment group has to be unique
CREATE UNIQUE INDEX UQ_experiment_groups__experiment_group
	ON experiment_groups (experiment_group);

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
	id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id UUID NOT NULL,
    experiment_group_id BIGINT NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active'
);

--Each user / experiment group should be unique
CREATE UNIQUE INDEX UQ_experiment_group_assignments
	ON experiment_group_assignments (user_id, experiment_group_id);

--Each row should be assigned to a user
ALTER TABLE experiment_group_assignments
    CONSTRAINT fk_experiment_group_assignments__users
    FOREIGN KEY(user_id)
    REFERENCES users(id);

--Each row should be assigned to an experiment group
ALTER TABLE experiment_group_assignments
    CONSTRAINT fk_experiment_group_assignments__experiment_groups
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
	id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    experiment_group_id bigint NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active',
    experiment_sub_group VARCHAR(250) NOT NULL,
    assignment_order SMALLINT NOT NULL, --the order in which to assign this sub_group to a user (e.g., if a user gets a set of experiments each week, we want to assign Week 1 first, then Week 2, then Week 3)
);

--Each sub_group has to be associated with an experiment_group
ALTER TABLE experiment_sub_groups
    CONSTRAINT fk_experiment_sub_groups__experiment_groups
    FOREIGN KEY(experiment_group_id)
    REFERENCES experiment_groups(id)

--Each experiment_group / experiment_sub_group combination has to be unique
CREATE UNIQUE INDEX UQ_experiment_sub_groups__experiment_sub_group_combo
	ON experiment_sub_groups (experiment_group_id, experiment_sub_group);

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
	id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id UUID NOT NULL,
    experiment_sub_group_id BIGINT NOT NULL,
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
	id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    experiment_sub_group_id bigint NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active',
    experiment VARCHAR NOT NULL,
);

--Each experiment has to be associated with an experiment_sub_group
ALTER TABLE experiments
    CONSTRAINT fk_experiments__experiment_sub_groups
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
	id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    experiment_id bigint NOT NULL,
    observation_prompt VARCHAR NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active',
);

--Each observation_prompt has to be associated with an experiment
ALTER TABLE observation_prompts
    CONSTRAINT fk_observation_prompts__experiments
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
	id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id UUID NOT NULL,
    observation_prompt_id bigint NOT NULL,
    observation VARCHAR NOT NULL,
);

--Each observation has to be associated with an observation_prompt
ALTER TABLE observations
    CONSTRAINT fk_observations__observation_prompts
    FOREIGN KEY(observation_prompt_id)
    REFERENCES observation_prompts(id);

--Each observation has to be associated with a user
ALTER TABLE observations
    CONSTRAINT fk_observations__users
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
	id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    public_user_id VARCHAR(6) NOT NULL DEFAULT LEFT(md5(random()::text),6),
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
    CONSTRAINT fk_user_lookups__users
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

--Test email uniqueness constraint
INSERT INTO users(email, first_name, last_name) 
VALUES
	('tristanzucker@gmail.com', 'Tristan', 'Zucker'),
	('tristanzucker@gmail.com', 'Tristan 2', 'Zucker');

--Test email validity constraint
INSERT INTO users(email, first_name, last_name) 
VALUES
	('tristanzucker@@gmail.com', 'Tristan', 'Zucker');

--Test updated time
INSERT INTO users(email, first_name, last_name, preferred_first_name) 
VALUES
	('tristanzucker@gmail.com', 'Tristan', 'Zucker', ''),
	('tristanandrewzucker@gmail.com', 'Tristan 2', 'Zucker', 'Tristan Second');

-- Wait for a second, then run
UPDATE users
SET preferred_first_name = 'Tristan 2nd'
WHERE 
	preferred_first_name = 'Tristan Second' AND
	email = 'tristanandrewzucker@gmail.com';

--Check inserts, update time
SELECT * FROM users;










/***
Create experiments table.

Purpose: store all available experiments.
***/

CREATE TABLE experiments(
	id UUID DEFAULT uuid_generate_v4(),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	name VARCHAR NOT NULL,
	description VARCHAR NOT NULL,
	active BOOLEAN NOT NULL DEFAULT TRUE,
	PRIMARY KEY (id)
);

--Each experiment.name has to be unique
CREATE UNIQUE INDEX experiment_name_unique_index
	ON experiments (name);

--Automatically update updated_time.
CREATE TRIGGER experiments_set_updated_time
BEFORE UPDATE ON experiments
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();

/***

Create experiment_preferences table.

Purpose: store current and previous preferences for regarding experiments.
***/

CREATE TABLE experiment_preferences(
	id UUID DEFAULT uuid_generate_v4(),
	user_id UUID,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	active BOOLEAN NOT NULL DEFAULT TRUE,
	PRIMARY KEY (id),
	CONSTRAINT fk_users --a preference has to be associated with a user
		FOREIGN KEY(user_id)
			REFERENCES users(id)
);

--Each user_id can only have one active preference
CREATE UNIQUE INDEX user_id_has_one_active_experiment_preference_index
	ON experiment_preferences (user_id) WHERE active = TRUE;
	
--Automatically update updated_time.
CREATE TRIGGER experiment_preferences_set_updated_time
BEFORE UPDATE ON experiment_preferences
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();

--Test that each user_id can only have one active preference
WITH new_rows(user_email) AS
(VALUES
	('tristanzucker@gmail.com') ,
	('tristanandrewzucker@gmail.com')
)  
INSERT INTO experiment_preferences(user_id) 
SELECT users.id
FROM users
	JOIN new_rows n
	ON users.email = n.user_email;

--Try to insert the same user again 
/*Should fail as experiment_preferences.active defaults to TRUE and violates each 
user_id can only have one active preference*/
WITH new_rows(user_email) AS
(VALUES
	('tristanzucker@gmail.com') 
)  
INSERT INTO experiment_preferences(user_id) 
SELECT users.id
FROM users
	JOIN new_rows n
	ON users.email = n.user_email;
	
--Try to insert the same user again but with active = FALSE so that it doesn't violate constraint
WITH new_rows(user_email, active) AS
(VALUES
	('tristanzucker@gmail.com', FALSE) 
)  
INSERT INTO experiment_preferences(user_id, active) 
SELECT users.id, n.active
FROM users
	JOIN new_rows n
	ON users.email = n.user_email;
	
--Check that everything worked
SELECT * FROM experiment_preferences;