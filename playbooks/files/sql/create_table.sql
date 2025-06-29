-- create_table.sql
CREATE TABLE &tablename (
    id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name VARCHAR2(50),
    department VARCHAR2(50),
    salary NUMBER
);
