/*
** $Id: lua.c $
** Lua stand-alone interpreter
** See Copyright Notice in lua.h
*/

#define lua_c

#include "lprefix.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <signal.h>

#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>

#include <errno.h>

#include "lua.h"

#include "lauxlib.h"
#include "lualib.h"

#if !defined(LUA_PROGNAME)
#define LUA_PROGNAME "lua"
#endif

#if !defined(LUA_INIT_VAR)
#define LUA_INIT_VAR "LUA_INIT"
#endif

#define LUA_INITVARVERSION LUA_INIT_VAR LUA_VERSUFFIX

//
// BEGIN FUZZING CODE
//

#define REPRL_CRFD 100
#define REPRL_CWFD 101
#define REPRL_DRFD 102
#define REPRL_DWFD 103

#define SHM_SIZE 0x100000
#define MAX_EDGES ((SHM_SIZE - 4) * 8)

#define CHECK(cond)                            \
  if (!(cond))                                 \
  {                                            \
    fprintf(stderr, "\"" #cond "\" failed\n"); \
    _exit(-1);                                 \
  }

struct shmem_data
{
  uint32_t num_edges;
  unsigned char edges[];
};

struct shmem_data *__shmem;
uint32_t *__edges_start, *__edges_stop;

void __sanitizer_cov_reset_edgeguards()
{
  uint64_t N = 0;
  for (uint32_t *x = __edges_start; x < __edges_stop && N < MAX_EDGES; x++)
    *x = ++N;
}

void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop)
{
  // Avoid duplicate initialization
  if (start == stop || *start)
    return;

  if (__edges_start != NULL || __edges_stop != NULL)
  {
    fprintf(stderr, "Coverage instrumentation is only supported for a single module\n");
    _exit(-1);
  }

  __edges_start = start;
  __edges_stop = stop;

  // Map the shared memory region
  const char *shm_key = getenv("SHM_ID");
  if (!shm_key)
  {
    puts("[COV] no shared memory bitmap available, skipping");
    __shmem = (struct shmem_data *)malloc(SHM_SIZE);
  }
  else
  {
    int fd = shm_open(shm_key, O_RDWR, S_IREAD | S_IWRITE);
    if (fd <= -1)
    {
      fprintf(stderr, "Failed to open shared memory region: %s\n", strerror(errno));
      _exit(-1);
    }

    __shmem = (struct shmem_data *)mmap(0, SHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (__shmem == MAP_FAILED)
    {
      fprintf(stderr, "Failed to mmap shared memory region\n");
      _exit(-1);
    }
  }

  __sanitizer_cov_reset_edgeguards();

  __shmem->num_edges = stop - start;
  printf("[COV] edge counters initialized. Shared memory: %s with %u edges\n", shm_key, __shmem->num_edges);
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard)
{
  // There's a small race condition here: if this function executes in two threads for the same
  // edge at the same time, the first thread might disable the edge (by setting the guard to zero)
  // before the second thread fetches the guard value (and thus the index). However, our
  // instrumentation ignores the first edge (see libcoverage.c) and so the race is unproblematic.
  uint32_t index = *guard;
  // If this function is called before coverage instrumentation is properly initialized we want to return early.
  if (!index)
    return;
  __shmem->edges[index / 8] |= 1 << (index % 8);
  *guard = 0;
}

//
// END FUZZING CODE
//

static lua_State *globalL = NULL;

static const char *progname = LUA_PROGNAME;

#if defined(LUA_USE_POSIX) /* { */

/*
** Use 'sigaction' when available.
*/
static void setsignal(int sig, void (*handler)(int))
{
  struct sigaction sa;
  sa.sa_handler = handler;
  sa.sa_flags = 0;
  sigemptyset(&sa.sa_mask); /* do not mask any signal */
  sigaction(sig, &sa, NULL);
}

#else /* }{ */

#define setsignal signal

#endif /* } */

/*
** Hook set by signal function to stop the interpreter.
*/
static void lstop(lua_State *L, lua_Debug *ar)
{
  (void)ar;                   /* unused arg. */
  lua_sethook(L, NULL, 0, 0); /* reset hook */
  luaL_error(L, "interrupted!");
}

/*
** Function to be called at a C signal. Because a C signal cannot
** just change a Lua state (as there is no proper synchronization),
** this function only sets a hook that, when called, will stop the
** interpreter.
*/
static void laction(int i)
{
  int flag = LUA_MASKCALL | LUA_MASKRET | LUA_MASKLINE | LUA_MASKCOUNT;
  setsignal(i, SIG_DFL); /* if another SIGINT happens, terminate process */
  lua_sethook(globalL, lstop, flag, 1);
}

static void print_usage(const char *badoption)
{
  lua_writestringerror("%s: ", progname);
  if (badoption[1] == 'e' || badoption[1] == 'l')
    lua_writestringerror("'%s' needs argument\n", badoption);
  else
    lua_writestringerror("unrecognized option '%s'\n", badoption);
  lua_writestringerror(
      "usage: %s [options] [script [args]]\n"
      "Available options are:\n"
      "  -e stat   execute string 'stat'\n"
      "  -i        enter interactive mode after executing 'script'\n"
      "  -l mod    require library 'mod' into global 'mod'\n"
      "  -l g=mod  require library 'mod' into global 'g'\n"
      "  -v        show version information\n"
      "  -E        ignore environment variables\n"
      "  -W        turn warnings on\n"
      "  --        stop handling options\n"
      "  -         stop handling options and execute stdin\n",
      progname);
}

/*
** Prints an error message, adding the program name in front of it
** (if present)
*/
static void l_message(const char *pname, const char *msg)
{
  if (pname)
    lua_writestringerror("%s: ", pname);
  lua_writestringerror("%s\n", msg);
}

/*
** Check whether 'status' is not OK and, if so, prints the error
** message on the top of the stack. It assumes that the error object
** is a string, as it was either generated by Lua or by 'msghandler'.
*/
static int report(lua_State *L, int status)
{
  if (status != LUA_OK)
  {
    const char *msg = lua_tostring(L, -1);
    l_message(progname, msg);
    lua_pop(L, 1); /* remove message */
  }
  return status;
}

/*
** Message handler used to run all chunks
*/
static int msghandler(lua_State *L)
{
  const char *msg = lua_tostring(L, 1);
  if (msg == NULL)
  {                                          /* is error object not a string? */
    if (luaL_callmeta(L, 1, "__tostring") && /* does it have a metamethod */
        lua_type(L, -1) == LUA_TSTRING)      /* that produces a string? */
      return 1;                              /* that is the message */
    else
      msg = lua_pushfstring(L, "(error object is a %s value)",
                            luaL_typename(L, 1));
  }
  luaL_traceback(L, L, msg, 1); /* append a standard traceback */
  return 1;                     /* return the traceback */
}

/*
** Interface to 'lua_pcall', which sets appropriate message function
** and C-signal handler. Used to run all chunks.
*/
static int docall(lua_State *L, int narg, int nres)
{
  int status;
  int base = lua_gettop(L) - narg;  /* function index */
  lua_pushcfunction(L, msghandler); /* push message handler */
  lua_insert(L, base);              /* put it under function and args */
  globalL = L;                      /* to be available to 'laction' */
  setsignal(SIGINT, laction);       /* set C-signal handler */
  status = lua_pcall(L, narg, nres, base);
  setsignal(SIGINT, SIG_DFL); /* reset C-signal handler */
  lua_remove(L, base);        /* remove message handler from the stack */
  return status;
}

static void print_version(void)
{
  lua_writestring(LUA_COPYRIGHT, strlen(LUA_COPYRIGHT));
  lua_writeline();
}

/*
** Create the 'arg' table, which stores all arguments from the
** command line ('argv'). It should be aligned so that, at index 0,
** it has 'argv[script]', which is the script name. The arguments
** to the script (everything after 'script') go to positive indices;
** other arguments (before the script name) go to negative indices.
** If there is no script name, assume interpreter's name as base.
*/
static void createargtable(lua_State *L, char **argv, int argc, int script)
{
  int i, narg;
  if (script == argc)
    script = 0;               /* no script name? */
  narg = argc - (script + 1); /* number of positive indices */
  lua_createtable(L, narg, script + 1);
  for (i = 0; i < argc; i++)
  {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i - script);
  }
  lua_setglobal(L, "arg");
}

static int dochunk(lua_State *L, int status)
{
  if (status == LUA_OK)
    status = docall(L, 0, 0);
  return report(L, status);
}

static int dofile(lua_State *L, const char *name)
{
  return dochunk(L, luaL_loadfile(L, name));
}

static int dostring(lua_State *L, const char *s, const char *name)
{
  return dochunk(L, luaL_loadbuffer(L, s, strlen(s), name));
}

/*
** Receives 'globname[=modname]' and runs 'globname = require(modname)'.
*/
static int dolibrary(lua_State *L, char *globname)
{
  int status;
  char *modname = strchr(globname, '=');
  if (modname == NULL)  /* no explicit name? */
    modname = globname; /* module name is equal to global name */
  else
  {
    *modname = '\0'; /* global name ends here */
    modname++;       /* module name starts after the '=' */
  }
  lua_getglobal(L, "require");
  lua_pushstring(L, modname);
  status = docall(L, 1, 1); /* call 'require(modname)' */
  if (status == LUA_OK)
    lua_setglobal(L, globname); /* globname = require(modname) */
  return report(L, status);
}

/*
** Push on the stack the contents of table 'arg' from 1 to #arg
*/
static int pushargs(lua_State *L)
{
  int i, n;
  if (lua_getglobal(L, "arg") != LUA_TTABLE)
    luaL_error(L, "'arg' is not a table");
  n = (int)luaL_len(L, -1);
  luaL_checkstack(L, n + 3, "too many arguments to script");
  for (i = 1; i <= n; i++)
    lua_rawgeti(L, -i, i);
  lua_remove(L, -i); /* remove table from the stack */
  return n;
}

static int handle_script(lua_State *L, char **argv)
{
  int status;
  const char *fname = argv[0];
  if (strcmp(fname, "-") == 0 && strcmp(argv[-1], "--") != 0)
    fname = NULL; /* stdin */
  status = luaL_loadfile(L, fname);
  if (status == LUA_OK)
  {
    int n = pushargs(L); /* push arguments to script */
    status = docall(L, n, LUA_MULTRET);
  }
  return report(L, status);
}

/* bits of various argument indicators in 'args' */
#define has_error 1 /* bad option */
#define has_i 2     /* -i */
#define has_v 4     /* -v */
#define has_e 8     /* -e */
#define has_E 16    /* -E */

#define has_r 32 /* -r */

/*
** Traverses all arguments from 'argv', returning a mask with those
** needed before running any Lua code (or an error code if it finds
** any invalid argument). 'first' returns the first not-handled argument
** (either the script name or a bad argument in case of error).
*/
static int collectargs(char **argv, int *first)
{
  int args = 0;
  int i;
  for (i = 1; argv[i] != NULL; i++)
  {
    *first = i;
    if (argv[i][0] != '-') /* not an option? */
      return args;         /* stop handling options */
    switch (argv[i][1])
    {                         /* else check option */
    case '-':                 /* '--' */
      if (argv[i][2] != '\0') /* extra characters after '--'? */
        return has_error;     /* invalid option */
      *first = i + 1;
      return args;
    case '\0':     /* '-' */
      return args; /* script "name" is '-' */
    case 'E':
      if (argv[i][2] != '\0') /* extra characters? */
        return has_error;     /* invalid option */
      args |= has_E;
      break;
    case 'W':
      if (argv[i][2] != '\0') /* extra characters? */
        return has_error;     /* invalid option */
      break;
    case 'i':
      args |= has_i; /* (-i implies -v) */ /* FALLTHROUGH */
    case 'v':
      if (argv[i][2] != '\0') /* extra characters? */
        return has_error;     /* invalid option */
      args |= has_v;
      break;
    case 'e':
      args |= has_e; /* FALLTHROUGH */
    case 'l':        /* both options need an argument */
      if (argv[i][2] == '\0')
      {      /* no concatenated argument? */
        i++; /* try next 'argv' */
        if (argv[i] == NULL || argv[i][0] == '-')
          return has_error; /* no next argument or it is another option */
      }
      break;
    case 'r':
      args |= has_r; /* Fuzzing Mode */
      break;
    default: /* invalid option */
      return has_error;
    }
  }
  *first = i; /* no script name */
  return args;
}

/*
** Processes options 'e' and 'l', which involve running Lua code, and
** 'W', which also affects the state.
** Returns 0 if some code raises an error.
*/
static int runargs(lua_State *L, char **argv, int n)
{
  int i;
  for (i = 1; i < n; i++)
  {
    int option = argv[i][1];
    lua_assert(argv[i][0] == '-'); /* already checked */
    switch (option)
    {
    case 'e':
    case 'l':
    {
      int status;
      char *extra = argv[i] + 2; /* both options need an argument */
      if (*extra == '\0')
        extra = argv[++i];
      lua_assert(extra != NULL);
      status = (option == 'e')
                   ? dostring(L, extra, "=(command line)")
                   : dolibrary(L, extra);
      if (status != LUA_OK)
        return 0;
      break;
    }
    case 'W':
      lua_warning(L, "@on", 0); /* warnings on */
      break;
    }
  }
  return 1;
}

static int handle_luainit(lua_State *L)
{
  const char *name = "=" LUA_INITVARVERSION;
  const char *init = getenv(name + 1);
  if (init == NULL)
  {
    name = "=" LUA_INIT_VAR;
    init = getenv(name + 1); /* try alternative name */
  }
  if (init == NULL)
    return LUA_OK;
  else if (init[0] == '@')
    return dofile(L, init + 1);
  else
    return dostring(L, init, name);
}

/*
** {==================================================================
** Read-Eval-Print Loop (REPL)
** ===================================================================
*/

#if !defined(LUA_PROMPT)
#define LUA_PROMPT "> "
#define LUA_PROMPT2 ">> "
#endif

#if !defined(LUA_MAXINPUT)
#define LUA_MAXINPUT 512
#endif

/*
** lua_stdin_is_tty detects whether the standard input is a 'tty' (that
** is, whether we're running lua interactively).
*/
#if !defined(lua_stdin_is_tty) /* { */

#if defined(LUA_USE_POSIX) /* { */

#include <unistd.h>
#define lua_stdin_is_tty() isatty(0)

#elif defined(LUA_USE_WINDOWS) /* }{ */

#include <io.h>
#include <windows.h>

#define lua_stdin_is_tty() _isatty(_fileno(stdin))

#else                        /* }{ */

/* ISO C definition */
#define lua_stdin_is_tty() 1 /* assume stdin is a tty */

#endif /* } */

#endif /* } */

/*
** lua_readline defines how to show a prompt and then read a line from
** the standard input.
** lua_saveline defines how to "save" a read line in a "history".
** lua_freeline defines how to free a line read by lua_readline.
*/
#if !defined(lua_readline) /* { */

#if defined(LUA_USE_READLINE) /* { */

#include <readline/readline.h>
#include <readline/history.h>
#define lua_initreadline(L) ((void)L, rl_readline_name = "lua")
#define lua_readline(L, b, p) ((void)L, ((b) = readline(p)) != NULL)
#define lua_saveline(L, line) ((void)L, add_history(line))
#define lua_freeline(L, b) ((void)L, free(b))

#else /* }{ */

#define lua_initreadline(L) ((void)L)
#define lua_readline(L, b, p)                                   \
  ((void)L, fputs(p, stdout), fflush(stdout), /* show prompt */ \
   fgets(b, LUA_MAXINPUT, stdin) != NULL)     /* get line */
#define lua_saveline(L, line) \
  {                           \
    (void)L;                  \
    (void)line;               \
  }
#define lua_freeline(L, b) \
  {                        \
    (void)L;               \
    (void)b;               \
  }

#endif /* } */

#endif /* } */

/*
** Return the string to be used as a prompt by the interpreter. Leave
** the string (or nil, if using the default value) on the stack, to keep
** it anchored.
*/
static const char *get_prompt(lua_State *L, int firstline)
{
  if (lua_getglobal(L, firstline ? "_PROMPT" : "_PROMPT2") == LUA_TNIL)
    return (firstline ? LUA_PROMPT : LUA_PROMPT2); /* use the default */
  else
  { /* apply 'tostring' over the value */
    const char *p = luaL_tolstring(L, -1, NULL);
    lua_remove(L, -2); /* remove original value */
    return p;
  }
}

/* mark in error messages for incomplete statements */
#define EOFMARK "<eof>"
#define marklen (sizeof(EOFMARK) / sizeof(char) - 1)

/*
** Check whether 'status' signals a syntax error and the error
** message at the top of the stack ends with the above mark for
** incomplete statements.
*/
static int incomplete(lua_State *L, int status)
{
  if (status == LUA_ERRSYNTAX)
  {
    size_t lmsg;
    const char *msg = lua_tolstring(L, -1, &lmsg);
    if (lmsg >= marklen && strcmp(msg + lmsg - marklen, EOFMARK) == 0)
    {
      lua_pop(L, 1);
      return 1;
    }
  }
  return 0; /* else... */
}

/*
** Prompt the user, read a line, and push it into the Lua stack.
*/
static int pushline(lua_State *L, int firstline)
{
  char buffer[LUA_MAXINPUT];
  char *b = buffer;
  size_t l;
  const char *prmt = get_prompt(L, firstline);
  int readstatus = lua_readline(L, b, prmt);
  if (readstatus == 0)
    return 0;    /* no input (prompt will be popped by caller) */
  lua_pop(L, 1); /* remove prompt */
  l = strlen(b);
  if (l > 0 && b[l - 1] == '\n')            /* line ends with newline? */
    b[--l] = '\0';                          /* remove it */
  if (firstline && b[0] == '=')             /* for compatibility with 5.2, ... */
    lua_pushfstring(L, "return %s", b + 1); /* change '=' to 'return' */
  else
    lua_pushlstring(L, b, l);
  lua_freeline(L, b);
  return 1;
}

/*
** Try to compile line on the stack as 'return <line>;'; on return, stack
** has either compiled chunk or original line (if compilation failed).
*/
static int addreturn(lua_State *L)
{
  const char *line = lua_tostring(L, -1); /* original line */
  const char *retline = lua_pushfstring(L, "return %s;", line);
  int status = luaL_loadbuffer(L, retline, strlen(retline), "=stdin");
  if (status == LUA_OK)
  {
    lua_remove(L, -2);       /* remove modified line */
    if (line[0] != '\0')     /* non empty? */
      lua_saveline(L, line); /* keep history */
  }
  else
    lua_pop(L, 2); /* pop result from 'luaL_loadbuffer' and modified line */
  return status;
}

/*
** Read multiple lines until a complete Lua statement
*/
static int multiline(lua_State *L)
{
  for (;;)
  { /* repeat until gets a complete statement */
    size_t len;
    const char *line = lua_tolstring(L, 1, &len);         /* get what it has */
    int status = luaL_loadbuffer(L, line, len, "=stdin"); /* try it */
    if (!incomplete(L, status) || !pushline(L, 0))
    {
      lua_saveline(L, line); /* keep history */
      return status;         /* cannot or should not try to add continuation line */
    }
    lua_pushliteral(L, "\n"); /* add newline... */
    lua_insert(L, -2);        /* ...between the two lines */
    lua_concat(L, 3);         /* join them */
  }
}

/*
** Read a line and try to load (compile) it first as an expression (by
** adding "return " in front of it) and second as a statement. Return
** the final status of load/call with the resulting function (if any)
** in the top of the stack.
*/
static int loadline(lua_State *L)
{
  int status;
  lua_settop(L, 0);
  if (!pushline(L, 1))
    return -1;                           /* no input */
  if ((status = addreturn(L)) != LUA_OK) /* 'return ...' did not work? */
    status = multiline(L);               /* try as command, maybe with continuation lines */
  lua_remove(L, 1);                      /* remove line from the stack */
  lua_assert(lua_gettop(L) == 1);
  return status;
}

/*
** Prints (calling the Lua 'print' function) any values on the stack
*/
static void l_print(lua_State *L)
{
  int n = lua_gettop(L);
  if (n > 0)
  { /* any result to be printed? */
    luaL_checkstack(L, LUA_MINSTACK, "too many results to print");
    lua_getglobal(L, "print");
    lua_insert(L, 1);
    if (lua_pcall(L, n, 0, 0) != LUA_OK)
      l_message(progname, lua_pushfstring(L, "error calling 'print' (%s)",
                                          lua_tostring(L, -1)));
  }
}

/*
** Do the REPL: repeatedly read (load) a line, evaluate (call) it, and
** print any results.
*/
static void doREPL(lua_State *L)
{
  int status;
  const char *oldprogname = progname;
  progname = NULL; /* no 'progname' on errors in interactive mode */
  lua_initreadline(L);
  while ((status = loadline(L)) != -1)
  {
    if (status == LUA_OK)
      status = docall(L, 0, LUA_MULTRET);
    if (status == LUA_OK)
      l_print(L);
    else
      report(L, status);
  }
  lua_settop(L, 0); /* clear stack */
  lua_writeline();
  progname = oldprogname;
}

/* }================================================================== */
int test_crash(lua_State* L){
  char shell_code[5] = "1123";
  char* of = "asdhofhuisfhdgkjsdhgjkbnc12834728974398273498237498237498kaljsdklajsdlkjasdiaojsdiaj237489";
  strcpy(shell_code - 10, of);
  printf("%s\n",shell_code);
  return 0;
}

static int do_Fuzzing(int argc, char **argv)
{
  char helo[] = "HELO";
  if (write(REPRL_CWFD, helo, 4) != 4 || read(REPRL_CRFD, helo, 4) != 4) {
      printf("Invalid HELO response from parent\n");
      return EXIT_FAILURE;
  }

  if (memcmp(helo, "HELO", 4) != 0) {
      printf("Invalid response from parent\n");
      _exit(-1);
  }

  while(1){
    // the main fuzz loop
    int script = 0,result = 0, status = 0;

    // receive the script
    size_t script_size = 0;
    unsigned action;
    CHECK(read(REPRL_CRFD, &action, 4) == 4);
    if (action == 'cexe') {
        CHECK(read(REPRL_CRFD, &script_size, 8) == 8);
    } else {
        fprintf(stderr, "Unknown action: %u\n", action);
        _exit(-1);
    }

    char* script_src = malloc(script_size + 1);
    memset(script_src, 0, script_size + 1);
    char* ptr = script_src;
    size_t remaining = script_size;
    while (remaining > 0) {
        ssize_t rv = read(REPRL_DRFD, ptr, remaining);
        if (rv <= 0) {
            fprintf(stderr, "Failed to load script\n");
            _exit(-1);
        }
        remaining -= rv;
        ptr += rv;
    }
    script_src[script_size] = '\0';
    // create the new Lua State
    lua_State *L = luaL_newstate();
    if (L == NULL)
    {
      l_message(argv[0], "cannot create state: not enough memory");
      return EXIT_FAILURE;
    }
    lua_register(L,"test_crash", test_crash);
    luaL_openlibs(L);                      /* open standard libraries */
    createargtable(L, argv, argc, script); /* create table 'arg' */
    lua_gc(L, LUA_GCGEN, 0, 0);            /* GC in generational mode */

    if (handle_luainit(L) != LUA_OK) /* run LUA_INIT */
      return EXIT_FAILURE; 

    if(LUA_OK == (result = dostring(L, script_src, "chunk")))
    { /* execute the test case successfully */
      l_print(L);
    }
    else 
    { /* execute hte test case failure */
      report(L, status);
    }
  
    lua_close(L);
    status = (result & 0xff) << 8;
    fflush(stdout);
    fflush(stderr);
    CHECK(write(REPRL_CWFD, &status, 4) == 4);
    __sanitizer_cov_reset_edgeguards();
  }
}

/*
** Main body of stand-alone interpreter (to be called in protected mode).
** Reads the options and handles them all.
*/
static int pmain(lua_State *L)
{
  int argc = (int)lua_tointeger(L, 1);
  char **argv = (char **)lua_touserdata(L, 2);
  int script;
  int args = collectargs(argv, &script);
  luaL_checkversion(L); /* check that interpreter has correct version */
  if (argv[0] && argv[0][0])
    progname = argv[0];
  if (args == has_error)
  {                            /* bad arg? */
    print_usage(argv[script]); /* 'script' has index of bad arg. */
    return 0;
  }

  if (args & has_v) /* option '-v'? */
    print_version();
  if (args & has_E)
  {                        /* option '-E'? */
    lua_pushboolean(L, 1); /* signal for libraries to ignore env. vars. */
    lua_setfield(L, LUA_REGISTRYINDEX, "LUA_NOENV");
  }
  luaL_openlibs(L);                      /* open standard libraries */
  createargtable(L, argv, argc, script); /* create table 'arg' */
  lua_gc(L, LUA_GCGEN, 0, 0);            /* GC in generational mode */
  if (!(args & has_E))
  {                                  /* no option '-E'? */
    if (handle_luainit(L) != LUA_OK) /* run LUA_INIT */
      return 0;                      /* error running LUA_INIT */
  }
  if (!runargs(L, argv, script)) /* execute arguments -e and -l */
    return 0;                    /* something failed */
  if (script < argc &&           /* execute main script (if there is one) */
      handle_script(L, argv + script) != LUA_OK)
    return 0;
  if (args & has_i) /* -i option? */
    doREPL(L);      /* do read-eval-print loop */
  else if (script == argc && !(args & (has_e | has_v)))
  { /* no arguments? */
    if (lua_stdin_is_tty())
    { /* running in interactive mode? */
      print_version();
      doREPL(L); /* do read-eval-print loop */
    }
    else
      dofile(L, NULL); /* executes stdin as a file */
  }
  lua_pushboolean(L, 1); /* signal no errors */
  return 1;
}

// test fork server Or just close the old state and create a new state
int test(int argc, char **argv)
{
  /*
  char source1[200] = "function fact (n) \n if n == 0 then \n return 1 \n else \n return n * fact(n-1) \n end \n end \n a = 2 \n print(a) \n fact(a)\n a=9\0";
  char source2[200] = "print(a)\n\0";
  // memset(source,0,100);
  int status;

  status = dostring(L,source1,"123");
  if (status == LUA_OK)
    l_print(L);
  else
    report(L,status);
  status = dostring(L,source2,"124");
  if (status == LUA_OK)
    l_print(L);
  else
    report(L,status);
  */
  int script;
  int args = collectargs(argv, &script);
  clock_t start, finish;
  start = clock();
  if (args & has_r){
    // just close the old state and create a new state
    for(int i = 0; i < 1000; i++){
      lua_State *L = luaL_newstate();
      if (L == NULL)
      {
        l_message(argv[0], "cannot create state: not enough memory");
        return EXIT_FAILURE;
      }
      luaL_openlibs(L);                      /* open standard libraries */
      createargtable(L, argv, argc, script); /* create table 'arg' */
      lua_gc(L, LUA_GCGEN, 0, 0);            /* GC in generational mode */

      if (handle_luainit(L) != LUA_OK) /* run LUA_INIT */
        return 0; 
      lua_close(L); 
    }
    finish = clock();
    printf("%f\n", (double)(finish - start));
  }
  else {
    // fork server
    for(int i = 0; i < 1000; i++)
    {
      lua_State *L = luaL_newstate();
      if (L == NULL)
      {
        l_message(argv[0], "cannot create state: not enough memory");
        return EXIT_FAILURE;
      }
      luaL_openlibs(L);                      /* open standard libraries */
      createargtable(L, argv, argc, script); /* create table 'arg' */
      lua_gc(L, LUA_GCGEN, 0, 0);            /* GC in generational mode */

      if (handle_luainit(L) != LUA_OK) /* run LUA_INIT */
        return 0;

      
      int pid = fork();
      if(pid == 0){
        // child
        lua_close(L);
        exit(0);
      }
      else {
        // parent
        wait(NULL);
      }
    }
    finish = clock();
    printf("%f\n", (double)(finish - start));

  }
  return 0;
}


int main(int argc, char **argv)
{
  int status, result;
  int script;
  int args = collectargs(argv, &script);
  if (args & has_r) /* option '-r' */
  {
    return do_Fuzzing(argc, argv);
    // return test(argc,argv);
  }
  lua_State *L = luaL_newstate(); /* create state */
  lua_register(L,"test_crash", test_crash);
  if (L == NULL)
  {
    l_message(argv[0], "cannot create state: not enough memory");
    return EXIT_FAILURE;
  }
  lua_pushcfunction(L, &pmain);   /* to call 'pmain' in protected mode */
  lua_pushinteger(L, argc);       /* 1st argument */
  lua_pushlightuserdata(L, argv); /* 2nd argument */
  status = lua_pcall(L, 2, 1, 0); /* do the call */
  result = lua_toboolean(L, -1);  /* get result */
  report(L, status);
  lua_close(L);
  return (result && status == LUA_OK) ? EXIT_SUCCESS : EXIT_FAILURE;
}
