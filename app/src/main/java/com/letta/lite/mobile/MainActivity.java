package com.letta.lite.mobile;

import android.os.Bundle;
import androidx.appcompat.app.AppCompatActivity;

public class MainActivity extends AppCompatActivity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // 加载你的布局文件（activity_main.xml）
        setContentView(R.layout.activity_main);
    }
}
