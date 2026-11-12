Compile-time stand-ins for the few Android classes DnsVpn.java uses, so
`javac` needs no android.jar. They are never put in the app: on the phone
the real classes are used. Constants are written so javac does not copy
their values (it reads the phone's own).
