DBDIR_MEMORY <- ":memory:"

check_flag <- function(x) {
  if (is.null(x) || length(x) != 1 || is.na(x) || !is.logical(x)) {
    stop("flags need to be scalar logicals")
  }
}

extptr_str <- function(e, n = 5) {
  x <- rethrow_rapi_ptr_to_str(e)
  substr(x, nchar(x) - n + 1, nchar(x))
}

drv_to_string <- function(drv) {
  if (!is(drv, "duckdb_driver")) {
    stop("pass a duckdb_driver object")
  }
  sprintf(
    "<duckdb_driver dbdir='%s' read_only=%s bigint=%s>",
    drv@dbdir,
    drv@read_only,
    drv@convert_opts$bigint
  )
}

driver_registry <- new.env(parent = emptyenv())

#' @description
#' `duckdb()` creates or reuses a database instance.
#'
#' @param environment_scan Set to `TRUE` to treat
#'   data frames from the calling environment as tables.
#'   If a database table with the same name exists, it takes precedence.
#'   The default of this setting may change in a future version.
#'
#' @return `duckdb()` returns an object of class [duckdb_driver-class].
#'
#' @import methods DBI
#' @export
duckdb <- function(
  dbdir = DBDIR_MEMORY,
  read_only = FALSE,
  bigint = "numeric",
  config = list(),
  ...,
  environment_scan = FALSE
) {
  check_flag(read_only)
  if (...length() > 0) {
    stop("... must be empty")
  }

  convert_opts <- duckdb_convert_opts(bigint = bigint)

  dbdir <- path_normalize(dbdir)
  if (dbdir != DBDIR_MEMORY) {
    drv <- driver_registry[[dbdir]]
    # We reuse an existing driver object if the database is still alive.
    # If not, we fall back to creating a new driver object with a new database.
    if (!is.null(drv) && rethrow_rapi_lock(drv@database_ref)) {
      # We don't care about different read_only or config settings here.
      # The bigint setting can be actually picked up by dbConnect(), we update it here.
      drv@convert_opts <- convert_opts
      drv@bigint <- convert_opts$bigint
      return(drv)
    }
  }

  # R packages are not allowed to write extensions into home directory, so use R_user_dir instead
  if (!("extension_directory" %in% names(config))) {
    config["extension_directory"] <- file.path(tools::R_user_dir("duckdb", "data"), "extensions")
  }
  if (!("secret_directory" %in% names(config))) {
    config["secret_directory"] <- file.path(tools::R_user_dir("duckdb", "data"), "stored_secrets")
  }

  # Always create new database for in-memory,
  # allows isolation and mixing different configs
  drv <- new(
    "duckdb_driver",
    config = config,
    database_ref = rethrow_rapi_startup(dbdir, read_only, config, environment_scan),
    dbdir = dbdir,
    read_only = read_only,
    convert_opts = convert_opts,
    bigint = convert_opts$bigint
  )

  if (dbdir != DBDIR_MEMORY) {
    driver_registry[[dbdir]] <- drv
  }

  reg.finalizer(drv@database_ref, onexit = TRUE, rapi_shutdown)

  drv
}

#' @description
#' `duckdb_shutdown()` shuts down a database instance.
#'
#' @return `dbDisconnect()` and `duckdb_shutdown()` are called for their
#'   side effect.
#' @rdname duckdb
#' @export
duckdb_shutdown <- function(drv) {
  if (!is(drv, "duckdb_driver")) {
    stop("pass a duckdb_driver object")
  }
  if (!dbIsValid(drv)) {
    warning("invalid driver object, already closed?")
    invisible(FALSE)
  }
  rethrow_rapi_shutdown(drv@database_ref)

  if (drv@dbdir != DBDIR_MEMORY) {
    rm(list = drv@dbdir, envir = driver_registry)
  }

  invisible(TRUE)
}

#' @description
#' Return an [adbcdrivermanager::adbc_driver()] for use with Arrow Database
#' Connectivity via the adbcdrivermanager package.
#'
#' @return An object of class "adbc_driver"
#' @rdname duckdb
#' @export
#' @examplesIf requireNamespace("adbcdrivermanager", quietly = TRUE)
#' library(adbcdrivermanager)
#' with_adbc(db <- adbc_database_init(duckdb_adbc()), {
#'   as.data.frame(read_adbc(db, "SELECT 1 as one;"))
#' })
duckdb_adbc <- function() {
  init_func <- structure(rethrow_rapi_adbc_init_func(), class = "adbc_driver_init_func")
  adbcdrivermanager::adbc_driver(init_func, subclass = "duckdb_driver_adbc")
}

# Registered in zzz.R
adbc_database_init.duckdb_driver_adbc <- function(driver, ...) {
  adbcdrivermanager::adbc_database_init_default(
    driver,
    list(...),
    subclass = "duckdb_database_adbc"
  )
}

adbc_connection_init.duckdb_database_adbc <- function(database, ...) {
  adbcdrivermanager::adbc_connection_init_default(
    database,
    list(...),
    subclass = "duckdb_connection_adbc"
  )
}

adbc_statement_init.duckdb_connection_adbc <- function(connection, ...) {
  adbcdrivermanager::adbc_statement_init_default(
    connection,
    list(...),
    subclass = "duckdb_statement_adbc"
  )
}

is_installed <- function(pkg) {
  as.logical(requireNamespace(pkg, quietly = TRUE)) == TRUE
}

check_tz <- function(timezone) {
  if (!is.null(timezone) && timezone == "") {
    return("")
  }

  if (is.null(timezone) || !timezone %in% OlsonNames()) {
    warning(
      "Invalid time zone '", timezone, "', ",
      "falling back to UTC.\n",
      "Set the `timezone_out` argument to a valid time zone.\n",
      call. = FALSE
    )
    return("UTC")
  }

  timezone
}

path_normalize <- function(path) {
  if (path == "" || path == DBDIR_MEMORY) {
    return(DBDIR_MEMORY)
  }

  out <- normalizePath(path, mustWork = FALSE)

  # Stable results are only guaranteed if the file exists
  if (!file.exists(out)) {
    on.exit(unlink(out))
    writeLines(character(), out)
    out <- normalizePath(out, mustWork = TRUE)
  }
  out
}
