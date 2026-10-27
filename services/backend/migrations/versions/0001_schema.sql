CREATE TABLE users (
	id VARCHAR NOT NULL, 
	email VARCHAR NOT NULL, 
	password VARCHAR NOT NULL, 
	failed_attempts INTEGER NOT NULL, 
	locked_until TIMESTAMP WITH TIME ZONE NOT NULL, 
	PRIMARY KEY (id), 
	UNIQUE (email)
);
CREATE TABLE devices (
	id VARCHAR NOT NULL, 
	owner_id VARCHAR NOT NULL, 
	name VARCHAR NOT NULL, 
	token_digest VARCHAR NOT NULL, 
	points JSONB NOT NULL, 
	calibration_id VARCHAR NOT NULL, 
	simulated INTEGER NOT NULL, 
	last_seen TIMESTAMP WITH TIME ZONE, 
	PRIMARY KEY (id), 
	FOREIGN KEY(owner_id) REFERENCES users (id), 
	UNIQUE (token_digest)
);
CREATE TABLE sessions (
	id VARCHAR NOT NULL, 
	owner_id VARCHAR NOT NULL, 
	title VARCHAR NOT NULL, 
	family VARCHAR NOT NULL, 
	expected VARCHAR NOT NULL, 
	symptoms VARCHAR NOT NULL, 
	supply_v FLOAT NOT NULL, 
	diagnosis_mode VARCHAR NOT NULL, 
	state VARCHAR NOT NULL, 
	version INTEGER NOT NULL, 
	specification JSONB NOT NULL, 
	spec_version INTEGER NOT NULL, 
	analysis_steps INTEGER NOT NULL, 
	pending_test JSONB, 
	created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(owner_id) REFERENCES users (id)
);
CREATE INDEX ix_sessions_owner_id ON sessions (owner_id);
CREATE TABLE tokens (
	digest VARCHAR NOT NULL, 
	user_id VARCHAR NOT NULL, 
	kind VARCHAR NOT NULL, 
	expires TIMESTAMP WITH TIME ZONE NOT NULL, 
	PRIMARY KEY (digest), 
	FOREIGN KEY(user_id) REFERENCES users (id)
);
CREATE TABLE analysis_jobs (
	kind VARCHAR NOT NULL, 
	status VARCHAR NOT NULL, 
	attempts INTEGER NOT NULL, 
	lease_until TIMESTAMP WITH TIME ZONE NOT NULL, 
	lease_token VARCHAR, 
	error VARCHAR, 
	id VARCHAR NOT NULL, 
	session_id VARCHAR NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(session_id) REFERENCES sessions (id)
);
CREATE INDEX ix_analysis_jobs_session_id ON analysis_jobs (session_id);
CREATE INDEX ix_analysis_jobs_status ON analysis_jobs (status);
CREATE TABLE evidence (
	key VARCHAR NOT NULL, 
	mime VARCHAR NOT NULL, 
	sha256 VARCHAR NOT NULL, 
	size INTEGER NOT NULL, 
	client_id VARCHAR NOT NULL, 
	id VARCHAR NOT NULL, 
	session_id VARCHAR NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
	PRIMARY KEY (id), 
	UNIQUE (session_id, client_id), 
	UNIQUE (key), 
	FOREIGN KEY(session_id) REFERENCES sessions (id)
);
CREATE INDEX ix_evidence_session_id ON evidence (session_id);
CREATE TABLE hardware_commands (
	device_id VARCHAR NOT NULL, 
	status VARCHAR NOT NULL, 
	deadline TIMESTAMP WITH TIME ZONE NOT NULL, 
	payload JSONB NOT NULL, 
	result JSONB, 
	id VARCHAR NOT NULL, 
	session_id VARCHAR NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(device_id) REFERENCES devices (id), 
	FOREIGN KEY(session_id) REFERENCES sessions (id)
);
CREATE INDEX ix_hardware_commands_session_id ON hardware_commands (session_id);
CREATE TABLE hypotheses (
	data JSONB NOT NULL, 
	id VARCHAR NOT NULL, 
	session_id VARCHAR NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(session_id) REFERENCES sessions (id)
);
CREATE INDEX ix_hypotheses_session_id ON hypotheses (session_id);
CREATE TABLE interventions (
	description VARCHAR NOT NULL, 
	confirmed_by VARCHAR NOT NULL, 
	id VARCHAR NOT NULL, 
	session_id VARCHAR NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(confirmed_by) REFERENCES users (id), 
	FOREIGN KEY(session_id) REFERENCES sessions (id)
);
CREATE INDEX ix_interventions_session_id ON interventions (session_id);
CREATE TABLE measurements (
	client_id VARCHAR NOT NULL, 
	point_id VARCHAR NOT NULL, 
	value FLOAT NOT NULL, 
	unit VARCHAR NOT NULL, 
	source VARCHAR NOT NULL, 
	measured_at TIMESTAMP WITH TIME ZONE NOT NULL, 
	calibration_id VARCHAR, 
	phase VARCHAR NOT NULL, 
	id VARCHAR NOT NULL, 
	session_id VARCHAR NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
	PRIMARY KEY (id), 
	UNIQUE (session_id, client_id), 
	FOREIGN KEY(session_id) REFERENCES sessions (id)
);
CREATE INDEX ix_measurements_session_id ON measurements (session_id);
CREATE TABLE model_runs (
	data JSONB NOT NULL, 
	id VARCHAR NOT NULL, 
	session_id VARCHAR NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(session_id) REFERENCES sessions (id)
);
CREATE INDEX ix_model_runs_session_id ON model_runs (session_id);
CREATE TABLE pairings (
	digest VARCHAR NOT NULL, 
	session_id VARCHAR NOT NULL, 
	expires TIMESTAMP WITH TIME ZONE NOT NULL, 
	used INTEGER NOT NULL, 
	PRIMARY KEY (digest), 
	FOREIGN KEY(session_id) REFERENCES sessions (id)
);
CREATE TABLE session_events (
	sequence INTEGER NOT NULL, 
	kind VARCHAR NOT NULL, 
	data JSONB NOT NULL, 
	id VARCHAR NOT NULL, 
	session_id VARCHAR NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
	PRIMARY KEY (id), 
	UNIQUE (session_id, sequence), 
	FOREIGN KEY(session_id) REFERENCES sessions (id)
);
CREATE INDEX ix_session_events_session_id ON session_events (session_id);
CREATE TABLE session_members (
	session_id VARCHAR NOT NULL, 
	user_id VARCHAR NOT NULL, 
	role VARCHAR NOT NULL, 
	PRIMARY KEY (session_id, user_id), 
	FOREIGN KEY(session_id) REFERENCES sessions (id), 
	FOREIGN KEY(user_id) REFERENCES users (id)
);
CREATE TABLE verifications (
	data JSONB NOT NULL, 
	id VARCHAR NOT NULL, 
	session_id VARCHAR NOT NULL, 
	created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(session_id) REFERENCES sessions (id)
);
CREATE INDEX ix_verifications_session_id ON verifications (session_id);
