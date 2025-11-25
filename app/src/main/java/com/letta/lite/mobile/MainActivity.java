package com.letta.lite.mobile;

import android.os.Bundle;
import androidx.appcompat.app.AppCompatActivity;

public class MainActivity extends AppCompatActivity {
    // 新增：静态代码块，启动时自动加载Rust核心库（关键修复闪退）
    static {
        System.loadLibrary("letta_core"); // 库名是"letta_core"（去掉.so和前面的lib）
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // 加载你的布局文件（activity_main.xml）
        setContentView(R.layout.activity_main);
    }
}
