-- table_employee.sql
CREATE TABLE &username..employee (
    id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR2(50),
    department VARCHAR2(50),
    salary NUMBER
);

INSERT INTO &username..employee (name, department, salary) VALUES ('Alice', '&env', 70000);
INSERT INTO &username..employee (name, department, salary) VALUES ('Bob', '&env', 65000);
INSERT INTO &username..employee (name, department, salary) VALUES ('Charlie', '&env', 72000);

COMMIT;
