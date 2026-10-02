import java.util.ArrayList;
import java.util.List;
import java.util.Random;

/** A fake JVM service for the demo cluster: a live heap for jcmd heap dumps and profiles. */
public class Inventory {
    public static void main(String[] args) throws Exception {
        Random random = new Random();
        List<long[]> cache = new ArrayList<>();
        System.out.println("INFO  [inventory-service] JVM " + Runtime.version() + " started");
        for (long tick = 1; ; tick++) {
            cache.add(new long[2048 + random.nextInt(4096)]);
            if (cache.size() > 4000) cache.subList(0, 1000).clear();
            int sku = 10000 + random.nextInt(90000);
            System.out.println("INFO  [inventory-service] stock check sku=" + sku
                    + " warehouse=WH-" + (1 + random.nextInt(4)) + " available=" + random.nextInt(500));
            if (tick % 25 == 0) {
                Runtime rt = Runtime.getRuntime();
                System.out.println("DEBUG [inventory-service] heap used="
                        + (rt.totalMemory() - rt.freeMemory()) / (1024 * 1024) + "MiB cache=" + cache.size());
            }
            Thread.sleep(300 + random.nextInt(900));
        }
    }
}
