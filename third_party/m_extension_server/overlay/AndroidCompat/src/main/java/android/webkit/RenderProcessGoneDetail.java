package android.webkit;

/**
 * 桌面 JVM 上 AndroidCompat 的最小桩（upstream_src 的 android/webkit 目录漏了它）。
 *
 * <p>{@code KcefWebViewProvider.kt} 在 onRenderProcessTerminated 里创建匿名子类并覆盖
 * didCrash()/rendererPriorityAtExit()；{@code WebViewClient.java:585} 的
 * onRenderProcessGone(WebView, RenderProcessGoneDetail) 也以它为参数类型。缺这个类时
 * :AndroidCompat:compileKotlin 直接报 "Unresolved reference 'RenderProcessGoneDetail'"，
 * 整个 mihon_bridge 侧车 jar 编不出来（CI 里被 continue-on-error 吞成软失败）。
 *
 * <p>与 overlay/AndroidCompat/.../android/net/*.java 同一套路：只补签名、不含状态，
 * 桌面侧不跑 WebView 渲染进程，这两个值永远由匿名子类现场给出。
 * 必须与 Android SDK 的抽象类签名一致（无 final、无带参构造、两个抽象方法）。
 */
public abstract class RenderProcessGoneDetail {
    public RenderProcessGoneDetail() {}

    /** 渲染进程是否因崩溃退出。 */
    public abstract boolean didCrash();

    /** 退出时渲染进程的优先级；桌面桩用不到，由匿名子类返回 -1。 */
    public abstract int rendererPriorityAtExit();
}
