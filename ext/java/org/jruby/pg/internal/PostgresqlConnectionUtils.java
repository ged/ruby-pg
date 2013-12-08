package org.jruby.pg.internal;

import java.util.Properties;

public class PostgresqlConnectionUtils {
  public static String user(Properties props) {
    return props.getProperty("user", System.getProperty("user.name", ""));
  }

  public static String dbname(Properties prop) {
    return prop.getProperty("dbname", user(prop));
  }

  public static String password(Properties prop) {
    return prop.getProperty("password", null);
  }

  public static String options(Properties prop) {
    return prop.getProperty("options", "");
  }

  public static String ssl(Properties prop) {
    return prop.getProperty("sslmode", "disable");
  }


  public static int port(Properties prop) {
    return Integer.parseInt(prop.getProperty("port", "5432"));
  }

  public static String host(Properties prop) {
    String host = prop.getProperty("host");
    if (host == null) {
      return prop.getProperty("hostaddr", "localhost");
    }
    return host;
  }
}
