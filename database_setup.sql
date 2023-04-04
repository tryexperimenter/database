/*Allow for UUID as Primary Key

While it could be overkill for non-sensitive tables, we’re going to default to using a Universally Unique ID as our primary keys. Some background info is:

https://arctype.com/blog/postgres-uuid/
https://www.postgresql.org/docs/current/uuid-ossp.html 
*/
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

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
Create users table, trigger to automatically update updated_time.
***/

CREATE TABLE users(
	id UUID DEFAULT uuid_generate_v4(),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	email VARCHAR(30) NOT NULL,
	first_name VARCHAR(30) NOT NULL,
	last_name VARCHAR(30) NOT NULL,
	preferred_first_name VARCHAR(30),
	PRIMARY KEY (id)
);

--Each email can only be used by one user
CREATE UNIQUE INDEX user_email_unique_index
	ON users (email);

--Automatically update updated_time.
CREATE TRIGGER users_set_updated_time
BEFORE UPDATE ON users
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();

--Test email uniqueness constraint
INSERT INTO users(email, first_name, last_name) 
VALUES
	('tristanzucker@gmail.com', 'Tristan', 'Zucker'),
	('tristanzucker@gmail.com', 'Tristan 2', 'Zucker');
	
--Test updated time
INSERT INTO users(email, first_name, last_name, preferred_first_name) 
VALUES
	('tristanzucker@gmail.com', 'Tristan', 'Zucker', ''),
	('tristanandrewzucker@gmail.com', 'Tristan 2', 'Zucker', 'Tristan Second');

UPDATE users
SET preferred_first_name = 'Tristan 2nd'
WHERE 
	preferred_first_name = 'Tristan Second' AND
	email = 'tristanandrewzucker@gmail.com';

--Check inserts, updates
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