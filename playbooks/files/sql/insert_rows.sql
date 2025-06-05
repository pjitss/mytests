-- insert_rows.sql
INSERT INTO &tabname (name, department, salary) VALUES ('&emp1', '&dept1', &sal1);
INSERT INTO &tabname (name, department, salary) VALUES ('&emp2', '&dept2', &sal2);

COMMIT;
