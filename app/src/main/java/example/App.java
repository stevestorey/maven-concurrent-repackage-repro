package example;

public class App {
    public static void main(String[] args) throws Exception {
        Class.forName("jakarta.servlet.Filter");
        System.out.println("OK: " + example.lib.Greeter.greet() + ", provided dependencies are on the classpath");
    }
}
