DEFINE logdir = '&1'
DEFINE username = '&2'
CREATE DIRECTORY LOGDIR AS '&logdir';
SELECT '&username' AS entered_user FROM dual;