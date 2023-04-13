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
Tables and Purposes

groups - stores different groups a user could join (e.g., Mini Experiments; Dealing with a Difficult Boss)

sub_groups - stores different sub_groups within each group (e.g., Mini Experiments: Week 1; Mini Experiments: Week 2) and how to calculate this sub_group's start date (at least X days after the start date of the previous sub_group, day of week restriction (if we want to ensure that sub_group_action_templates always fall on the same day))

group_assignments - stores which groups a user is assigned to, the start_date of the assignment, and whether the assignment is active

sub_group_assignments - stores which sub_groups a user is assigned to, the start_date of the assignment, and whether the sub_group is active (sub_groups that have been completed are still considered active, inactive is used if we are pausing / cancelling the sub_group_assignment)

sub_group_action_templates - stores the different actions Experimenter will take for each sub_group and when to take them relative to the sub_group_assignments.start_date (number_of_days_offset, time_of_day)

sub_group_actions - stores the actions Experimenter will take / has taken for each user / sub_group combination and the datetime to take the action (based on sub_group_assignments, sub_group_action_templates.action_datetime_days_offset, and sub_group_action_templates.action_datetime_time_of_day)



***/


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
Table: groups

Purpose: a user gets assigned experiments based on the experiment group(s) they belong to

Examples: Mini Experiments; Dealing with a Difficult Boss
***/

CREATE TABLE groups(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status VARCHAR(30) NOT NULL DEFAULT 'active', --we want to be able to update an experiment group for new users (e.g., update the name) while at the same time preserving data of previous experimenters. by setting it to inactive, we will not assign any new experimenters to this group but will maintain the data for previous experimenters.
    group VARCHAR(250) NOT NULL
);

--Each group with status = active has to be unique
CREATE UNIQUE INDEX UQ_groups__group
	ON groups (group) WHERE status = 'active';

--Restrict values for status
ALTER TABLE groups
    ADD CONSTRAINT check_groups__status 
    CHECK (status IN ('active', 'inactive'));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__groups
BEFORE UPDATE ON groups
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();

/***
Table: group_assignments

Purpose: Record which experiment group a user is assigned to and whether they are actively experimenting with that group.

Examples: Tristan is currently assigned to the Mini Experiments group; Tristan is currently assigned to the Dealing with a Difficult Boss group
***/

CREATE TABLE group_assignments(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id UUID NOT NULL,
    group_id VARCHAR(20) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active',
    start_date DATE NOT NULL,
);

--Each user / experiment group should be unique
CREATE UNIQUE INDEX UQ_group_assignments
	ON group_assignments (user_id, group_id);

--Each row should be assigned to a user
ALTER TABLE group_assignments
    ADD CONSTRAINT fk_group_assignments__users
    FOREIGN KEY(user_id)
    REFERENCES users(id);

--Each row should be assigned to an experiment group
ALTER TABLE group_assignments
    ADD CONSTRAINT fk_group_assignments__groups
    FOREIGN KEY(group_id)
    REFERENCES groups(id);

--Restrict values for status
ALTER TABLE group_assignments
    ADD CONSTRAINT check_group_assignments__status
    CHECK (status IN ('active', 'paused', 'completed'));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__group_assignments
BEFORE UPDATE ON group_assignments
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();


/***
Table: sub_groups

Purpose: each group has one or more sub_groups. A sub_group is how we group experiments to assign to a user.

Examples: Week 1, Week 2, Week 3 (if a user gets a set of experiments each week); Beginner, Intermediate, and Advanced (if a user is going to get more and more difficult experiments over time)

Note: Every group has an sub_group = "Introduction" with assignment_order = 0. This is what we use to send the intro message to a user and calculate when to assign additional sub_groups.
***/

CREATE TABLE sub_groups(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    group_id VARCHAR(20) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active',
    sub_group VARCHAR(250) NOT NULL,
    assignment_order SMALLINT NOT NULL, --the order in which to assign this sub_group to a user (e.g., if a user gets a set of experiments each week, we want to assign Week 1 first, then Week 2, then Week 3)
    start_date_days_offset SMALLINT, --the start_date of any sub_group_assignment has to be this many days after the start_date of the previous sub_group_assignment (0 = same day, 1 = next day)
    start_date_day_of_week SMALLINT, --if used, the start_date of any sub_group_assignment has to be on this day of the week (if the min_start_date_days_offset does not fall on this day, the start_date will be the next time this day_of_week occurs)
);

--Each active group / sub_group combination has to be unique (we don't want to have two sub_groups with the same name)
CREATE UNIQUE INDEX UQ_sub_groups__sub_group_combo
	ON sub_groups (group_id, sub_group) WHERE status = 'active';

--Each active group / assignment order combination has to be unique (we don't want to have two sub_groups with assignment_order = 3... which one do we assign?)
CREATE UNIQUE INDEX UQ_sub_groups__group_assignment_order_combo
	ON sub_groups (group_id, assignment_order) WHERE status = 'active';

--Each sub_group has to be associated with an group
ALTER TABLE sub_groups
    ADD CONSTRAINT fk_sub_groups__groups
    FOREIGN KEY(group_id)
    REFERENCES groups(id);

--Restrict values for status
ALTER TABLE sub_groups
    ADD CONSTRAINT check_sub_groups__status 
    CHECK (status IN ('active', 'inactive'));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__sub_groups
BEFORE UPDATE ON sub_groups
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();

/***
Table: sub_group_assignments

Purpose: Record which experiment sub_groups a user is assigned to and whether the assignment is active

Examples: Tristan is currently assigned to the Mini Experiments - Week 1 (start_datetime: XXX), Mini Experiments - Week 2 (start_datetime: XXX)
***/

CREATE TABLE sub_group_assignments(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id UUID NOT NULL,
    sub_group_id VARCHAR(20) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active',
    start_date DATE NOT NULL,
);

--Each user / experiment sub_group should be unique
CREATE UNIQUE INDEX UQ_sub_group_assignments
	ON sub_group_assignments (user_id, sub_group_id);

--Each row should be assigned to a user
ALTER TABLE sub_group_assignments
    ADD CONSTRAINT fk_sub_group_assignments__users
    FOREIGN KEY(user_id)
    REFERENCES users(id);

--Each row should be assigned to an experiment group
ALTER TABLE sub_group_assignments
    ADD CONSTRAINT fk_sub_group_assignments__sub_groups
    FOREIGN KEY(sub_group_id)
    REFERENCES sub_groups(id);

--Restrict values for status
ALTER TABLE sub_group_assignments
    ADD CONSTRAINT check_sub_group_assignments__status
    CHECK (status IN ('active', 'paused', 'completed'));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__sub_group_assignments
BEFORE UPDATE ON sub_group_assignments
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();

/***
Table: sub_group_action_templates

Purpose: Store the potential actions that we can take for each sub_group

Examples: start_displaying_experiments in Experimenter Log, send initial message to user about their Week 1 experiments, send reminder message to user about their Week 1 experiments, send observation message to user about their Week 1 experiments
***/

CREATE TABLE sub_group_action_templates(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sub_group_id VARCHAR(20) NOT NULL,
    action_type VARCHAR(30) NOT NULL, --the type of action to take (e.g., send initial message, send reminder message, send observation message)
    action_datetime_days_offset SMALLINT NOT NULL, --the number of days after the start_date of the sub_group_assignment to take the action (0 = same day, 1 = next day, etc.)
    action_datetime_time_of_day TIME NOT NULL, --the time of day to take the action (e.g., 9:00 AM, 12:00 PM, 5:00 PM, etc.)    
);

--Each action_template has to be associated with an sub_group
ALTER TABLE sub_group_action_templates
    ADD CONSTRAINT fk_sub_group_action_templates__user
    FOREIGN KEY(user_id)
    REFERENCES users(id);

--Each assignment has to be associated with an sub_group
ALTER TABLE sub_group_action_templates
    ADD CONSTRAINT fk_sub_group_action_templates__sub_group
    FOREIGN KEY(sub_group_id)
    REFERENCES sub_groups(id);

--Restrict values for action_type
ALTER TABLE sub_group_actions
    ADD CONSTRAINT check_sub_group_actions__action_type
    CHECK (action_type IN (
        'start_displaying_sub_group', --display the sub_group in the Experimenter Log
        'send_initial_message', --send the initial message with the experiments to the user
        'send_reminder_message', --send a reminder message to the user to do their experiments
        'send_observation_message' --send a message to the user to ask them to answer their observation prompts
        ));

--Restrict values for action_status
ALTER TABLE sub_group_actions
    ADD CONSTRAINT check_sub_group_actions__action_status
    CHECK (action_status IN (
        'pending', --we have yet to take action
        'message_scheduled', -- message has been scheduled, but not sent
        'message_failed', -- message failed to send
        'message_sent', -- message has been sent
        'completed', 
        'cancelled'
        ));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__sub_group_actions
BEFORE UPDATE ON sub_group_actions
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();


/***
Table: sub_group_actions

Purpose: Store which sub_groups have been assigned to each user and which actions to take to communicate to users. We also use this table to know what experiments to display in the Experimenter Log.

Examples: Send initial message to user about their Week 1 experiments on Monday at 9 am ET. 
***/

CREATE TABLE sub_group_actions(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id UUID NOT NULL,
    sub_group_id VARCHAR(20) NOT NULL,
    action_type VARCHAR(30) NOT NULL, --the type of action to take (e.g., send initial message, send reminder message, send observation message)
    action_datetime TIMESTAMPTZ NOT NULL, --the date and time on which to take the action. Date: the next sub_group_action_templates.day_of_week that occurs after the sub_group_assignments.start_date
    action_status VARCHAR(30) NOT NULL --the status of the action (e.g., pending, completed)
);

--Each user should only get one action of a given type for a given sub_group
CREATE UNIQUE INDEX UQ_sub_group_actions
	ON sub_group_actions (user_id, sub_group_id, action_type);

--Each assignment has to be associated with a user
ALTER TABLE sub_group_actions
    ADD CONSTRAINT fk_sub_group_actions__user
    FOREIGN KEY(user_id)
    REFERENCES users(id);

--Each assignment has to be associated with an sub_group
ALTER TABLE sub_group_actions
    ADD CONSTRAINT fk_sub_group_actions__sub_group
    FOREIGN KEY(sub_group_id)
    REFERENCES sub_groups(id);

--Restrict values for action_type
ALTER TABLE sub_group_actions
    ADD CONSTRAINT check_sub_group_actions__action_type
    CHECK (action_type IN (
        'display_sub_group', --display the sub_group in the Experimenter Log
        'send_initial_message', --send the initial message with the experiments to the user
        'send_reminder_message', --send a reminder message to the user to do their experiments
        'send_observation_message' --send a message to the user to ask them to answer their observation prompts
        ));

--Restrict values for action_status
ALTER TABLE sub_group_actions
    ADD CONSTRAINT check_sub_group_actions__action_status
    CHECK (action_status IN (
        'pending', --we have yet to take action
        'message_scheduled', -- message has been scheduled, but not sent
        'message_failed', -- message failed to send
        'message_sent', -- message has been sent
        'completed', 
        'cancelled'
        ));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__sub_group_actions
BEFORE UPDATE ON sub_group_actions
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();


/***
Table: experiments

Purpose: This is the base unit of Experimenter - an experiment someone will carry out.

Note 1: Once someone has done an experiment / answered an observation prompt, we want to ensure that we always display the original text of the experiment / observation prompt in their Experimenter Log.

To accomplish this, we never update the text of an experiment group, experiment sub group, experiment, or observation prompt. Instead, we create a new version of the experiment group, experiment sub group, experiment, or observation prompt and set the prior version status = 'inactive'.

Note 2: We don't have a many-to-many relationship between groups / sub_groups / experiments because we might have the same experiment for two different groups / sub_groups, but choose to have different observation prompts depending on the context.

Examples: Ask somone "how do you really feel"?; Stay silent for ~10 minutes in a meeting and just observe.
***/

CREATE TABLE experiments(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sub_group_id VARCHAR(20) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active',
    experiment VARCHAR NOT NULL,
    display_order SMALLINT NOT NULL --the order in which to display these experiments
);

--Each active sub_group / experiment combination has to be unique (we don't want to have two of the same experiments in a subgroup)
CREATE UNIQUE INDEX UQ_experiments__sub_group_combo
	ON experiments (sub_group_id, experiment) WHERE status = 'active';

--Each active sub_group / display order combination has to be unique (we don't want to have two experiments with the same display order)
CREATE UNIQUE INDEX UQ_experiments__sub_group__display_order
	ON experiments (sub_group_id, display_order) WHERE status = 'active';

--Each experiment has to be associated with an sub_group
ALTER TABLE experiments
    ADD CONSTRAINT fk_experiments__sub_groups
    FOREIGN KEY(sub_group_id)
    REFERENCES sub_groups(id);

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
    status VARCHAR(30) NOT NULL DEFAULT 'active',
    observation_prompt VARCHAR NOT NULL,
    display_order SMALLINT NOT NULL --the order in which to display these observation prompts
);

--Each active experiment / observation prompt combination has to be unique (we don't want to have two of the same observation prompts for an experiment)
CREATE UNIQUE INDEX UQ_observation_prompts__experiments
	ON observation_prompts (experiment_id, observation_prompt) WHERE status = 'active';

--Each active experiment / display order combination has to be unique (we don't want to have two observation prompts with the same display order)
CREATE UNIQUE INDEX UQ_observation_prompts__experiments__display_order
	ON observation_prompts (experiment_id, display_order) WHERE status = 'active';

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
	id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id UUID NOT NULL,
    observation_prompt_id VARCHAR(20) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active', -- in case we want to allow users to delete their observations
    visibility VARCHAR(30) NOT NULL DEFAULT 'private', -- in case we want to allow users to make their observations public
    observation VARCHAR NOT NULL
);

--Each user / observation prompt can only have one active observation
CREATE UNIQUE INDEX UQ_observations__user_prompt
	ON observations (user_id, observation_prompt_id) WHERE status = 'active';

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

--Restrict values for status
ALTER TABLE observations
    ADD CONSTRAINT check_observations__status 
    CHECK (status IN ('active', 'inactive'));

--Restrict values for visibility
ALTER TABLE observations
    ADD CONSTRAINT check_observations__visibility
    CHECK (visibility IN ('private', 'public_anonymous'));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__observations
BEFORE UPDATE ON observations
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();


/***
Table: experiment_actions

Purpose: Record whether the user did the experiment, how they did it, and whether they want to keep doing it in the future.
***/

CREATE TABLE experiment_actions(
	id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id UUID NOT NULL,
    experiment_id VARCHAR(20) NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active', -- in case we want to allow users to delete their experiment_actions
    action_taken VARCHAR(30) NOT NULL DEFAULT 'experimented', -- in case we want to allow users to make their observations public
    action_description VARCHAR, -- what action the user took to experiment
    future_action VARCHAR -- whether the user wants to keep taking the action in the experiment in the future
);

--Each user / experiment_id can only have one active row
CREATE UNIQUE INDEX UQ_experiment_actions__user_experiment
	ON experiment_actions (user_id, experiment_id) WHERE status = 'active';

--Each experiment_action has to be associated with a user
ALTER TABLE experiment_actions
    ADD CONSTRAINT fk_experiment_actions__users
    FOREIGN KEY(user_id)
    REFERENCES users(id);

--Each experiment_action has to be associated with an experiment
ALTER TABLE experiment_actions
    ADD CONSTRAINT fk_experiment_actions__experiments
    FOREIGN KEY(experiment_id)
    REFERENCES experiments(id);

--Restrict values for status
ALTER TABLE experiment_actions
    ADD CONSTRAINT check_experiment_actions__status 
    CHECK (status IN ('active', 'inactive'));

--Restrict values for action_taken
ALTER TABLE experiment_actions
    ADD CONSTRAINT check_experiment_actions__action_taken
    CHECK (action_taken IN ('experimented', 'experimented_with_modifications', 'did_not_experiment'));

--Restrict values for future_action
ALTER TABLE experiment_actions
    ADD CONSTRAINT check_experiment_actions__future_action
    CHECK (future_action IN ('repeat_action', 'do_not_repeat_action', ''));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__experiment_actions
BEFORE UPDATE ON experiment_actions
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
    user_id UUID NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'active',
	public_user_id VARCHAR(6) NOT NULL DEFAULT custom_id(6)
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
Table: api_calls

Purpose: Provide a record of api_calls that are made.

***/

CREATE TABLE api_calls(
	id VARCHAR(20) PRIMARY KEY DEFAULT custom_id(20),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    environment VARCHAR(20) NOT NULL,
    endpoint VARCHAR(100) NOT NULL
);

--Restrict values for environment
ALTER TABLE api_calls
    ADD CONSTRAINT check_api_calls__environment
    CHECK (environment IN ('development', 'production'));

--Automatically update updated_time.
CREATE TRIGGER set_updated_time__api_calls
BEFORE UPDATE ON api_calls
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





